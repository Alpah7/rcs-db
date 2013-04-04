require 'mongoid'
require 'mongoid_geospatial'

require 'lrucache'

require_relative '../../rcs-intelligence/link_manager'

#module RCS
#module DB

class Entity
  extend RCS::Tracer
  include RCS::Tracer
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Geospatial

  # this is the type of entity: target, person, position, etc
  field :type, type: Symbol

  # the level of trust of the entity (manual, automatic, suggested, ghost)
  field :level, type: Symbol

  # membership of this entity (inside operation or target)
  field :path, type: Array

  field :name, type: String
  field :desc, type: String

  # list of grid id for the photos
  field :photos, type: Array, default: []

  # last known position of a target
  field :position, type: Point, spatial: true
  # position_addr contains {time, accuracy}
  field :position_attr, type: Hash, default: {}

  # accounts for this entity
  embeds_many :handles, class_name: "EntityHandle"
  embeds_many :links, class_name: "EntityLink"

  # for the access control
  has_and_belongs_to_many :users, :dependent => :nullify, :autosave => true, inverse_of: nil

  index({name: 1}, {background: true})
  index({type: 1}, {background: true})
  index({path: 1}, {background: true})
  index({"handles.type" => 1}, {background: true})
  index({"handles.handle" => 1}, {background: true})

  spatial_index :position

  store_in collection: 'entities'

  scope :targets, where(type: :target)
  scope :persons, where(type: :person)
  scope :positions, where(type: :position)

  after_create :create_callback
  before_destroy :destroy_callback
  after_update :notify_callback

  def create_callback
    # make item accessible to the users of the parent operation
    parent = ::Item.find(self.path.last)
    self.users = parent.users

    RCS::DB::PushManager.instance.notify('entity', {id: self._id, action: 'create'})
  end

  def notify_callback
    # we are only interested if the properties changed are:
    interesting = ['name', 'desc', 'last_position', 'handles', 'links']
    return if not interesting.collect {|k| changes.include? k}.inject(:|)

    RCS::DB::PushManager.instance.notify('entity', {id: self._id, action: 'modify'})
  end

  def destroy_callback

    # remove all the inbound links in other entities
    self.links.each do |link|
      oe = ::Entity.find(link.le)
      next unless oe
      oe.links.where(le: self._id).destroy_all
      RCS::DB::PushManager.instance.notify('entity', {id: oe._id, action: 'modify'})
    end

    RCS::DB::PushManager.instance.notify('entity', {id: self._id, action: 'destroy'})
  end

  def merge(merging)
    raise "cannot merge different type of entities" unless self.type == merging.type
    raise "cannot merge entities belonging to different targets" unless self.path == merging.path

    # merge the name and description only if empty
    self.name = merging.name if self.name.nil? or self.name.eql? ""
    self.desc = merging.desc if self.desc.nil? or self.desc.eql? ""

    # merge the photos
    self.photos = self.photos + merging.photos

    # merge the handles
    merging.handles.each do |handle|
      self.handles << handle
    end

    #merge the positions
    merging.positions.each do |pos|
      self.positions << pos
    end

    # merge the current position only if newer
    self.current_position = merging.current_position if self.current_position.time < merging.current_position.time

    # save the mergee and destroy the merger
    self.save
    merging.destroy
  end

  def add_photo(content)
    # put the content in the grid collection of the target owning this entity
    id = RCS::DB::GridFS.put(content, {filename: self[:_id].to_s}, self.path.last.to_s)

    self.photos ||= []
    self.photos << id.to_s
    self.save

    return id
  end

  def del_photo(id)
    self.photos.delete(id)
    RCS::DB::GridFS.delete(id, self.path.last.to_s)
    self.save
  end

  def last_position=(hash)
    self.position = {latitude: hash[:latitude], longitude: hash[:longitude]}
    self.position_attr = {time: hash[:time], accuracy: hash[:accuracy]}
  end

  def last_position
    return {lat: self.position[:latitude], lng: self.position[:longitude], time: self.position_attr[:time], accuracy: self.position_attr[:accuracy]}
  end

  def self.name_from_handle(type, handle, target_id = nil)

    # use a class cache
    @@acc_cache ||= LRUCache.new(:ttl => 24.hour)

    return nil unless handle

    type = 'phone' if ['call', 'sms', 'mms'].include? type

    target = ::Item.find(target_id) if target_id

    # the scope of the search (within operation)
    path = target ? target.path.first : nil

    # check if already in cache
    search_key = "#{type}_#{handle}_#{path}"
    name = @@acc_cache.fetch(search_key)
    return name if name

    # find if there is an entity owning that handle
    search_query = {"handles.type" => type, "handles.handle" => handle}
    search_query['path'] = path if path

    entity = Entity.where(search_query).first
    if entity
      @@acc_cache.store(search_key, entity.name)
      return entity.name
    end

    # if no target (scope) is provided, don't search in the addressbook
    return nil unless target_id

    # use the fulltext (kw) search to be fast
    Evidence.collection_class(target_id).where({type: 'addressbook', :kw.all => handle.keywords }).each do |e|
      @@acc_cache.store(search_key, e[:data]['name'])
      return e[:data]['name']
    end

    return nil
  end

  def add_link(params)

    other_entity = params[:entity]

    raise "Cannot create link on itself" unless self != other_entity

    if params[:versus]
      versus = params[:versus].to_sym
      opposite_versus = versus if versus.eql? :both
      opposite_versus ||= (versus.eql? :in) ? :out : :in
    end

    # default is automatic
    params[:level] ||= :automatic

    trace :info, "Creating link between '#{self.name}' and '#{other_entity.name}' [#{params[:level]}, #{params[:type]}, #{versus}]"

    # create a link in this entity
    self_link = self.links.find_or_create_by(le: other_entity._id, level: params[:level], type: params[:type])
    self_link.first_seen = Time.now.getutc.to_i unless self_link.first_seen
    self_link.last_seen = Time.now.getutc.to_i
    self_link.add_versus(versus) if versus
    self_link.add_info params[:info] if params[:info]
    self_link.save

    # and also create the reverse in the other entity
    other_link = other_entity.links.find_or_create_by(le: self._id, level: params[:level], type: params[:type])
    other_link.first_seen = Time.now.getutc.to_i unless other_link.first_seen
    other_link.last_seen = Time.now.getutc.to_i
    other_link.add_versus(opposite_versus) if opposite_versus
    other_link.add_info params[:info] if params[:info]
    other_link.save

    # notify the links
    RCS::DB::PushManager.instance.notify('entity', {id: self._id, action: 'modify'})
    RCS::DB::PushManager.instance.notify('entity', {id: other_entity._id, action: 'modify'})

    return self_link
  end

  def del_link(params)
    other_entity = params[:entity]
    trace :info, "Deleting links between '#{self.name}' and '#{other_entity.name}'"

    self.links.where(le: other_entity._id).destroy_all
    other_entity.links.where(le: self._id).destroy_all

    # notify the links
    RCS::DB::PushManager.instance.notify('entity', {id: self._id, action: 'modify'})
    RCS::DB::PushManager.instance.notify('entity', {id: other_entity._id, action: 'modify'})
  end

end


class EntityHandle
  include Mongoid::Document
  include Mongoid::Timestamps

  embedded_in :entity

  # the level of trust of the entity
  field :level, type: Symbol

  field :type, type: Symbol
  field :name, type: String
  field :handle, type: String

  after_create :create_callback

  def create_callback
    # check if other entities have the same handle (it could be an identity relation)
    RCS::Intelligence::LinkManager.instance.check_identity(self._parent, self)
    # link any other entity to this new handle (based on aggregates)
    RCS::Intelligence::LinkManager.instance.link_handle(self._parent, self)
  end

end


class EntityLink
  include Mongoid::Document

  embedded_in :entity

  # linked entity
  field :le, type: Moped::BSON::ObjectId

  # the level of trust of the link (manual or automatic)
  field :level, type: Symbol
  # kind of link (identity, peer, position)
  field :type, type: Symbol

  # time of the first and last contact
  field :first_seen, type: Integer
  field :last_seen, type: Integer

  # versus of the link (:in, :out, :both)
  field :versus, type: Symbol

  # evidence type that refers to this link
  # or info for identity relation
  field :info, type: Array, default: []

  # relevance (tag)
  field :rel, type: Integer, default: 0

  def add_info(info)
    return if self.info.include? info
    self.info << info
  end

  def add_versus(versus)
    # already set
    return if self.versus.eql? versus

    # first time, set it as new
    if self.versus.nil?
      self.versus = versus
      return
    end

    # they are different, so overwrite it to both
    self.versus = :both
  end
end


#end # ::DB
#end # ::RCS