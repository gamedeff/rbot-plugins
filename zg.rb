#
# Zeitgeist Rubybot Plugin
# Copyright (C) 2012  Matthias Hecker (http://github.com/4poc)
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
begin
  require 'rubygems'
rescue LoadError
end
require 'rest_client'
require 'json'

# used to symbolize the yaml config file
module HashExtensions
  def symbolize_keys
    inject({}) do |acc, (k,v)|
      key = String === k ? k.to_sym : k
    value = Hash === v ? v.symbolize_keys : v
    acc[key] = value
    acc
    end
  end
end
Hash.send(:include, HashExtensions)

module ::Zeitgeist
  class HashObject
    def initialize(obj=nil)
      return if not obj
      obj.each_pair do |name, value|
        instance_variable_set("@#{name}", value)
        self.class.send('attr_reader', name.to_sym)
      end
    end
  end

  class Item < HashObject
    attr_reader :tags
    def initialize(item_obj, tags)
      super item_obj
      @image = Image.new self.image
      @tags = tags.map { |tag| Tag.new tag }
    end
  end

  class Image < HashObject
  end

  class Tag < HashObject
  end

  class Request
    def initialize(base_url, options = {})
      base_url = base_url[0...-1] if base_url =~ %r{/$}
      @base_url = base_url
      @email = options[:email] if options.has_key? :email
      @api_secret = options[:api_secret] if options.has_key? :api_secret 
    end

    # Tests if the provided api_secret and email are valid
    def auth?
      result = get('/api_secret')
      return true if result[:api_secret] == @api_secret and
                     result[:email] == @email
      false
    rescue Error => e
      return false
    end

    def upload(file, tags = '', announce = false)
      file = File.new(file, 'rb') if file.class == String
      result = post('/new', :image_upload => file, :tags => tags, :announce => (announce ? 'true' : 'false'))
      # deleteme Item.new(result[:items].first, result[:tags])
      result[:items].map do |item|
        Item.new(item, result[:tags])
      end
    end

    def remote(url, tags = '', announce = false)
      result = post('/new', :remote_url => url, :tags => tags, :announce => (announce ? 'true' : 'false'))
      result[:items].map do |item|
        Item.new(item, result[:tags])
      end
    end

    # Returns an Item and an array of associated Tags
    def item(id)
      result = get('/' + id.to_s)
      Item.new(result[:item], result[:tags])
    end

    def update(id, add_tags, del_tags)
      result = post('/update', :id => id, 
                               :add_tags => add_tags,
                               :del_tags => del_tags)
      Item.new(result[:item], result[:tags])
    end

    def delete(id)
      post('/delete', :id => id)[:id]
    end

    # returns {:id => [id of upvoted], :upvotes => [current number of upvotes]}
    def upvote(id, remove=false)
      post('/upvote', :id => id, 
                      :remove => remove.to_s)
    end
    
    private

    def get(path)
      rest_request(:get, path)
    end

    def post(path, payload)
      rest_request(:post, path, payload)
    end

    def rest_request(method, path, payload=nil)
      url = @base_url + path
      headers = { 'Accept' => 'application/json' }

      if @email and @api_secret
        headers.merge!({ 'X-API-Auth' => @email + '|' + @api_secret })
      end
      
      begin
        case method
        when :get
          response = RestClient.get(url, headers)
        when :post
          response = RestClient.post(url, payload, headers)
        end
      rescue RestClient::InternalServerError => e
        raise e if not e.response

        error = JSON.parse(e.response.to_str).symbolize_keys
        raise Error::create(error)
      rescue Exception => e
        raise ConnectionError.new(e.message)
      else
        JSON.parse(response.to_str).symbolize_keys
      end
    end
  end

  class Error < StandardError
    attr_reader :type #original error type
    def initialize(obj)
      @type = obj[:type]
      super obj[:message]
    end

    def self.create(obj)
      case obj[:type]
      when 'DuplicateError'
        DuplicateError.new(obj)
      when 'CreateItemError'
        CreateItemError.new(obj)
      when 'RemoteError'
        RemoteError.new(obj)
      else
        new(obj)
      end
    end
  end

  class DuplicateError < Error
    attr_reader :id
    def initialize(obj)
      @id = obj[:id]
      super obj
    end
  end

  class RemoteError < Error
    attr_reader :error
    attr_reader :url
    def initialize(obj)
      @error = Error::create(obj[:error])
      @url = obj[:url]
      super obj
    end
  end

  class CreateItemError < Error
    attr_reader :error
    attr_reader :items
    attr_reader :tags
    def initialize(obj)
      @error = Error::create(obj[:error])
      @items = obj[:items]
      @tags = obj[:tags]
      super obj
    end
  end

  class ConnectionError < Error
  end
end

class ZeitgeistPlugin < Plugin
  include Zeitgeist # include API

  Config.register(Config::StringValue.new('zg.base_url',
    :default => 'http://127.0.0.1:4567/',
    :desc => 'Base URL for the Zeitgeist installation.'))

  Config.register(Config::ArrayValue.new('zg.listen',
    :default => ['#example'],
    :desc => 'Default list of channel to listen for URLs.'))

  Config.register(Config::ArrayValue.new('zg.announce',
    :default => ['#example'],
    :desc => 'Channel announcements of new items.'))


  def help(plugin, topic='')
    host = URI.parse(@bot.config['zg.base_url']).host
    listen = @bot.config['zg.listen'].join ','

    h = '*%s* | media links in *%s* are published | messages starting with *#* are ignored | end message with *# tag1, tag2* to submit with tags | usage: zg [*command*] | commands: *(none)* user options/help; *show* item; *create*; *update*; *delete*; *upvote*; *auth* reg/login; *enable* option; *disable* option; *alt* set alternative nicks; *test* show auth status | /msg %s help zg *<command or topic>*' % [host, listen, @bot.nick]
    h << "\nQry/hl *apoc* with bugs, annoyances and feature requests ;)"

    case topic
    when 'show'
      h = '*zg show <ID>* - show information of the item specified by *ID*'

    when 'create'
      h = '*zg create <URL> [<TAG1, TAG2, ...>]* - submit link with tags (optional) | *URL* pointing to image/audio/video, direct links to jpg/gif/png files, youtube, vimeo, soundcloud, abload, flickr, fukung, imagenetz, imageshack, imgur, picpaste, twitpic, twitter (status with images), xkcd and yfrog links'

    when 'update'
      h = '*zg update <ID> [<TAG1, TAG2, ...>]* - update item specified by *ID* with comma seperated tag list | *-TAG* will remove *TAG* from item'

    when 'delete'
      h = '*zg delete <ID>* - delete an item specified by *ID* | non-admins can only delete their own items'

    when 'upvote'
      h = '*zg upvote [remove] <ID>* - upvote an item specified by *ID* or undo an previous upvote | if you are authenticated and enabled the shortupvote option, you can use *+1* in any channel message to upvote the last submitted item in that channel'

    when 'auth'
      h = '*zg auth <EMAIL> <API SECRET>* - authenticate yourself or update your email/key | you find your *API SECRET* here: %s' % [ @base_url + 'api_secret' ]

    when 'enable'
      h = '*zg enable <OPTION>* - enables an boolean *OPTION* | for a list of options and their values use the *zg* command'

    when 'disable'
      h = '*zg disable <OPTION>* - disables an boolean *OPTION* | for a list of options and their values use the *zg* command'

    when 'alt'
      h = '*zg alt <NICK>* - adds or removes a alternative *NICK*'

    when 'test'
      h = '*zg test* - check authentication against *%s* and show nickserv status' % host 

    when 'shortcuts'
      h = '*^[<ID/OFFSET>] [<TAG1, TAG2, ...>]* - used in channels the bot listens in, to show or update an item specified by *ID* or *OFFSET* (by default with -1/last, of the submitted items in that room) | you need to have the *shortcuts* option enabled'

    end

    colorize h
  end

  def initialize
    super
    @base_url = @bot.config['zg.base_url']
    @reg = @registry[:zg]
    if not @reg
      @reg = {
        :users => {},
        # links in listened channel are posted to zg and guest users
        # are notified that their links have been submitted. They are
        # informed that they can authenticate with the bot so they can
        # use the user features.
        :ignore_guests => [],
        :history => {}
      }
    end
    if not @reg.has_key? :history
      @reg[:history] = {}
    end
    @history = {}
    @errorlog = {} # logs item submission errors

    # send periodical WHOs in the channels listened:
    @who_timer = @bot.timer.add(60*5) do
      @bot.config['zg.listen'].each do |channel|
        debug 'send who to update registration data'
        @bot.sendq('WHO %s' % channel)
      end
    end
  end

  def cleanup
    @bot.timer.remove(@who_timer)
  end

  def join(m)
    debug 'send who because someone joined'
    @bot.sendq('WHO %s' % m.channel.to_s)
  end

  def save
    @registry[:zg] = @reg
  end

  def name
    'zg'
  end

  #############################################################################
  # Show user information
  #
  # Command: .zg
  # Params: -
  # Access: open
  def cmd_main(m, params=nil)
    # access control: open
    nick, user = auth m
    if not user
      host = URI.parse(@bot.config['zg.base_url']).host
      h = 'You\'re not yet recognized and thus post anonymously, if you do register an account at *%s* you can authenticate with the bot. This enables you to (as you wish) delete your submissions, you can also upvote items and enable bot features like channel shortcuts and notification messages. For more information on how to authenticate: */msg %s zg auth*' % [host, @bot.nick]

      m.reply colorize(h), :to => :private
    else
      h = 'You\'re recognized as *%s*. You\'ve got the following options:' % [user[:email]]
      h << ' | *shortcuts* (%s) - opt-in the ^ syntax: *help zg shortcuts*' % [user[:shortcuts] ? 'enabled' : 'disabled']
      h << ' | *shortupvotes* (%s) - opt-in the use of *+1* and *-1* for upvotes' % [user[:shortupvotes] ? 'enabled' : 'disabled']
      h << ' | *notify* (%s) - get queried about own submissions, taggings and upvotes' % [user[:notify] ? 'enabled' : 'disabled']
      h << ' | *nickserv* (%s) - increase security by enforcing nickserv identification' % [user[:nickserv] ? 'enabled' : 'disabled']
      h << ' | *alt* (%s) - alternative nicknames to recognize you under' % [user[:alt].length > 0 ? user[:alt].join(', ') : 'none']

      h << ' | (please read *help zg* for more information)'

      m.reply colorize(h), :to => :private
    end
  end

  #############################################################################
  # Show info how to auth, auth new user or change existing auth
  #
  # Command: .zg auth [email] [api_secret]
  # Params: :email (optional) email of (existing) zeitgeist account
  #         :api_secret (optional) shared secret key
  # Access: open
  def cmd_auth(m, params)
    nick, user = search_user m.source.to_s
    email = params[:email]
    api_secret = params[:api_secret]

    if not email or not api_secret
      h = 'To authenticate with your zeitgeist account or to change existing credentials, visit %s to get your api secret and set it with: *zg auth [EMAIL] [API SECRET]*' % ["#{@base_url}api_secret"]
      m.reply colorize(h), :to => :private
    else
      if valid? email, api_secret
        if not user
          create_user m.source.to_s, email, api_secret
        else
          user[:email] = email
          user[:api_secret] = api_secret
        end
        m.reply colorize('Success! You\'ve been authenticated as *%s* with your nickname %s. Now you can customize your settings: */msg %s zg* and will be recognized as %s.' % [email, nick, @bot.nick]), :to => :private
      else
        m.reply colorize('Unable to authenticate as *%s*.' % email), :to => :private
      end
    end
  end

  #############################################################################
  # Enable a boolean user option
  #
  # Command: .zg enable [option]
  # Params: :option string of an symbol option within the user hash
  # Access: restricted
  def cmd_enable(m, params)
    # access control: require authentication
    nick, user = auth m, true
    return if not user

    option = params[:option].to_sym
    if user.keys.include? option
      if user[option] == true
        m.reply 'Already enabled.'
      elsif user[option] == false
        user[option] = true
        m.okay
      else
        m.reply 'Invalid type.'
      end
    else
      m.reply 'Invalid option.'
    end
  end

  #############################################################################
  # Disable a boolean user option
  #
  # Command: .zg disable [option]
  # Params: :option string of an symbol option within the user hash 
  # Access: restricted
  def cmd_disable(m, params)
    # access control: require authentication
    nick, user = auth m, true
    return if not user

    option = params[:option].to_sym
    if user.keys.include? option
      if user[option] == true
        user[option] = false
        m.okay
      elsif user[option] == false
        m.reply 'Already disabled.'
      else
        m.reply 'Invalid type.'
      end
    else
      m.reply 'Invalid option.'
    end
  end

  #############################################################################
  # Adds or removes an alternative nickname from the :alt option
  #
  # A user can create aliases for himself under which he is recognized
  #
  # Command: .zg alt [alt_nick]
  # Params: :alt_nick nickname to add or remove
  # Access: restricted
  def cmd_alt(m, params)
    # access control: require authentication
    nick, user = auth m, true
    return if not user

    alt_nick = params[:alt_nick]
    if user[:alt].include? alt_nick
      user[:alt].delete alt_nick
      m.reply "No longer recogize #{Bold}#{alt_nick}#{NormalText} as a alternative nickname."
    else
      user[:alt] << alt_nick
      m.reply "Recognize #{Bold}#{alt_nick}#{NormalText} as a alternative nickname."
    end
  end

  #############################################################################
  # Tests the users email and api_secret's validity
  #
  # This performs an api request with the users email and api_secret
  # to test if the user is still authenticated.
  #
  # Command: .zg test
  # Params: -
  # Access: restricted
  def cmd_test(m, params)
    # access control: require authentication
    nick, user = auth m, true
    return if not user

    regged = nickserv? m.source

    # valid email/api-secret combination?
    if valid?(user[:email], user[:api_secret])
      m.reply "Zeitgeist authentication test #{Bold}successful#{NormalText} " +
        "for #{nick} using #{Bold}#{user[:email]}#{NormalText}. (#{regged ? 'nickserv registered' : 'not registered'})"
    else
      m.reply "Zeitgeist authentication test #{Bold}failed#{NormalText} " +
        "for #{nick} using #{Bold}#{user[:email]}#{NormalText}. (#{regged ? 'nickserv registered' : 'not registered'})"
    end
  end

  #############################################################################
  # Show infos about an item specified by ID
  #
  # Command: .zg show [id]
  # Params: :id integer id of item
  # Access: no-control
  def cmd_item_show(m, params)
    id = params[:id]
    begin
      item = api_request.item id
      m.reply item_to_s item
    rescue Exception => e
      m.reply "class:#{e.class} => #{e.message}"
    end
  end

  #############################################################################
  # Create an item by URL and tags
  #
  # Command: .zg create [url] [tags]
  # Params: :id integer id of item
  #         :url http:// link to media
  #         :tags a comma separated list of tags to add
  # Access: open (use account if possible)
  def cmd_item_create(m, params)
    nick, user = auth m
    url = params[:url]
    tags = params[:tags]

    begin
      req = api_request(user)
      item = req.remote(url, tags).first

      if m.channel
        push_history m.channel.to_s, item.id
      end

      m.reply "Item created: " + item_to_s(item)
    rescue ConnectionError => e
      m.reply "I can't connect to zeitgeist: #{e.message}"
    rescue CreateItemError => e
      error = e.error
      message = (error.class == RemoteError) ? error.error.message : error.message
      m.reply "Can't create item: #{message} (#{error.class.to_s})"
    rescue Error => e
      m.reply "#{Bold}Error occured:#{NormalText} #{e.message}"
    end
  end

  #############################################################################
  # Delete an item by ID
  #
  # Command: .zg delete [id]
  # Params: :id integer id of item
  # Access: restricted (needs nickserv)
  def cmd_item_delete(m, params)
    nick, user = auth(m, true, true)
    return if not user
    id = params[:id]
    
    begin
      req = api_request(user)
      confirm_id = req.delete(id).to_s
      m.reply "Item #{Bold + confirm_id + NormalText} deleted."
    rescue ConnectionError => e
      m.reply "I can't connect to zeitgeist: #{e.message}"
    rescue Error => e
      m.reply "#{Bold}Error occured:#{NormalText} #{e.message}"
    end
  end

  #############################################################################
  # Update an item by ID (add or delete tags)
  #
  # Command: .zg update [id] [tags]
  # Params: :id integer id of item
  #         :tags a comma separated list of tags to add or delete
  # Access: open (use account if possible)
  def cmd_item_update(m, params)
    nick, user = auth m
    id = params[:id]
    tags = params[:tags].join(' ').split(',')
    add_tags = []
    del_tags = []

    tags.each do |tag|
      tag.strip!
      if tag[0...1] == '-'
        del_tags << tag[1..-1]
      else
        add_tags << tag
      end
    end

    begin
      req = api_request(user)
      item = req.update(id, add_tags.join(','), del_tags.join(','))
      m.reply "updated item: " + item_to_s(item)
    rescue ConnectionError => e
      m.reply "I can't connect to zeitgeist: #{e.message}"
    rescue Error => e
      m.reply "#{Bold}Error occured:#{NormalText} #{e.message}"
    end
  end

  #############################################################################
  # Upvote an item specified by ID
  #
  # Command: .zg upvote [delete] [id]
  # Params: :remove (optional) if set, delete the upvote
  #         :id integer id of item
  # Access: restricted
  def cmd_item_upvote(m, params)
    # access control: require authentication
    nick, user = auth m, true
    return if not user
    id = params[:id]
    remove = params.has_key? :remove

    begin
      req = api_request(user)
      result = req.upvote(id, remove)

      m.reply result.inspect
      m.reply "#{Bold + result[:id].to_s + NormalText} #{remove ? 'upvote removed' : 'upvoted'} #{Bold + '+' + result[:upvotes].to_s + NormalText}"
    rescue ConnectionError => e
      m.reply "I can't connect to zeitgeist: #{e.message}"
    rescue Error => e
      m.reply "#{Bold}Error occured:#{NormalText} #{e.message}"
    end
  end

  #############################################################################
  # List the last 3 error messages occured
  #
  # Command: .zg error [channel]
  # Params: :channel (optional)
  # Access: open
  def cmd_error(m, params)
    if params.has_key? :channel
      channel = params[:channel]
    else
      channel = m.channel.to_s
    end

    if not @errorlog.has_key? channel
      m.reply 'no errors logged'
      return
    end

    h = 'Errors in %s:' % [channel]
    m.reply @errorlog.inspect
    (1..3).each do |i|
      obj = @errorlog[channel][i * -1]
      break if not obj
      time = obj[:time]
      error = obj[:error]

      h << ' *%d* - %s ' % [i, time.strftime('%d-%m-%Y %H:%M')]
      if error.class == RemoteError
        h << '(%s) %s' % [error.url, error.error.message]
      else
        h << '%s' % [error.message]
      end
    end
    m.reply colorize(h)
  end

  #############################################################################
  # Upvote an item specified by ID
  #
  # Command: .zg upvote [delete] [id]
  # Params: :remove (optional) if set, delete the upvote
  #         :id integer id of item
  # Access: restricted
  def cmd_item_announce(m, params)
    id = params[:id]

    req = api_request
    begin
      # query the item:
      item = req.item(id)

      @bot.config['zg.announce'].each do |channel|
        announce = "#{Bold}zeitgeist#{NormalText} submission - #{item_to_s(item)}"
        @bot.say(channel, announce)
        push_history channel, item.id
      end 

    rescue ConnectionError => e
      debug "I can't connect to zeitgeist: #{e.message}"
    rescue Error => e
      debug "#{Bold}Error occured:#{NormalText} #{e.message}"
    end
  end

  def message(m, dummy=nil)
    message = m.message.strip
    return if message[0...1] == '#'
    return if m.address?
    source = m.source.to_s
    channel = m.channel.to_s

    # this also ignores query messages, to post links there, just
    # use the zg create command
    return if not @bot.config['zg.listen'].include? channel

    # try to find the user: user maybe nil for guest postings
    # nick may also be nil hmm
    nick, user = auth m

    #
    # URLs IN CHANNEL MESSAGES
    #
    urls = message.scan(%r{(http[s]?://[^ \)\}\]]+)})
    if urls.length > 0
      debug "urls => #{urls.inspect}"
      urls.flatten! #since we're only interested in the first matching group

      # parse for tags on the end of the message
      # after the urls
      debug "urls => #{urls.inspect}"
      last_url_index = message.rindex(urls.last) + urls.last.length
      debug "last_url_index => #{last_url_index}"
      left = message[last_url_index..-1]
      if left.match %r{ #\s*([^#]+)$}
        tags = $1
      else
        tags = ''
      end

      # @bot.say 'apoc', "[DEBUG} hannel message with urls by #{nick || source}/#{user == nil ? 'guest' : 'auth'} urls:#{urls.inspect} tags:#{tags.inspect}"

      req = api_request(user)
      begin
        items = req.remote(urls, tags)

        # remember items submitted in channel
        items.each do |item|
          push_history channel, item.id
        end

        # prepare announce message:
        announce = "#{Bold + items.length.to_s + NormalText} item(s) submitted: #{items.map { |item| item_to_s(item)}.join(' | ')}"

        # guest user?
        if not user
          if not @reg.has_key? :ignore_guests
            @reg[:ignore_guests] = []
          end

          if not @reg[:ignore_guests].include? source
            # just inform them once!
            @reg[:ignore_guests] << source

            host = URI.parse(@bot.config['zg.base_url']).host
            m.reply colorize('The link(s) you\'ve mentioned in *%s* have been submitted to %s: %s' % [channel, host, announce]), :to => :private
            cmd_main(m)
            m.reply '(I won\'t bother you again with this don\'t worry)', :to => :private
          end
        elsif user[:notify]
          # @bot.say(source, )
          m.reply announce, :to => :private
        end

      rescue ConnectionError => e
        debug "I can't connect to zeitgeist: #{e.message}"
      rescue CreateItemError => e
        error = e.error
        if e.error.class == DuplicateError
          item = req.item(e.error.id) 
          m.reply "identical item found: #{item_to_s(item)}"
        end


        if not @errorlog.has_key? channel
          @errorlog[channel] = []
        end
        @errorlog[channel] << {
          :time => Time.now,
          :error => e.error
        }

        e.items.map {|item| push_history channel, item.id }
      rescue Error => e
        debug "#{Bold}Error occured:#{NormalText} #{e.message}"
      end


    end

    #
    # SHORTCUTS ^ or ~ in the beginning of a line to show items or tag/untag
    #
    if message.match /^(\^|~)(-?[0-9]+)? ?(.*)?$/
      return if not user or not user[:shortcuts]

      if not $2 or $2.empty?
        id = @reg[:history][channel][-1]
      elsif $2[0...1] == '-' # offset in history:
        id = @reg[:history][channel][$2.to_i] 
      else
        id = $2.to_i
      end

      req = api_request(user)
      begin


        # push_history channel, id

        if $3 and not $3.empty?
          tags = $3.split ','
          add_tags = []
          del_tags = []

          tags.each do |tag|
            tag.strip!
            if tag[0...1] == '-'
              del_tags << tag[1..-1]
            elsif tag[0...1] == '+'
              add_tags << tag[1..-1]
            else
              add_tags << tag
            end
          end

          # m.reply "add:#{add_tags.inspect} del:#{del_tags.inspect}"

          item = req.update(id, add_tags.join(','), del_tags.join(','))
          # m.reply 'item: ' + item_to_s(item)
          if user[:notify]
            # @bot.say(source, )
            m.reply "item tagged: #{item_to_s(item)}", :to => :private
          end
        else
          item = req.item(id)
          m.reply 'item: ' + item_to_s(item)
        end



      rescue ConnectionError => e
        debug "I can't connect to zeitgeist: #{e.message}"
      rescue Error => e
        debug "#{Bold}Error occured:#{NormalText} #{e.message}"
        # maybe tell the error but nothing else
      end



    end

    if message.match /([+\-])1/
      return if not user or not user[:shortupvotes]

      id = @reg[:history][channel][-1]

      remove = true
      remove = false if $1 == '+'

      req = api_request(user)
      begin
        req.upvote(id, remove)
        # response in query if notify
        if user[:notify]
          # @bot.say(source, )
          item = req.item(id)
          m.reply "item #{remove ? 'upvote removed' : 'upvoted'} #{item_to_s(item)}", :to => :private
        end
      rescue ConnectionError => e
        debug "I can't connect to zeitgeist: #{e.message}"
      rescue Error => e
        debug "#{Bold}Error occured:#{NormalText} #{e.message}"
      end

    end
  end

  #############################################################################
  private

  # returns true if the email/api_secret are valid: this performs
  # a API request with the X-API-Secret header and checks the response
  def valid?(email, api_secret)
    req = Request.new(@base_url, 
                      :email => email,
                      :api_secret => api_secret) 
    req.auth?
  end

  def api_request(user=nil)
    if user
      Request.new(@base_url, :email => user[:email], :api_secret => user[:api_secret])
    else
      Request.new(@base_url)
    end
  end

  # create a user instance (maybe abstract this out into a class?)
  def create_user(nick, email, api_secret)
    @reg[:users][nick] = {
      :email => email,
      :api_secret => api_secret,
      :shortcuts => false,
      :shortupvotes => false,
      :notify => false, # query user about his published items, taggings and upvotes
      :nickserv => false, # enforce nickserv authentication, needs it to set it
      :alt => [] # alternative nicknames
    }
  end

  # returns true if the user is identified/registerd with nickserv
  # botuser: a Irc::User instance
  def nickserv?(botuser)
    if botuser.respond_to? :registered # this is not part of official rbot atm.
      botuser.registered
    else
      false
    end
  end

  # search a user hash based on a Irc::User, also searches in alternative
  # nicks. Returns [(main)nick, user hash]
  # require_auth: if true and no user can be found reply with a error
  #               message and return nil
  # require_nickserv: overwrites the user option :nickserv, if the user
  #                   is not identified with nickserv reply a error message
  #                   and return nil
  def auth(m, require_auth=false, require_nickserv=false)
    # find user for source nick
    nick, user = search_user m.source.to_s

    # if auth is required:
    if not user and require_auth
      m.reply "You need to authenticate first, /msg #{@bot.nick} zg auth"
      return [nil, nil]
    end

    return [nil, nil] if not user

    # if nickserv is required by user authentication or the param
    if (user[:nickserv] or require_nickserv) and not nickserv? m.source
      m.reply "NickServ authentication required to continue."
      return [nil, nil]
    end

    return [nick, user]
  end
  
  # search a user hash by nickname, return [(main)nick, user hash]
  # main nick is the nickname the user has initially created his account with
  def search_user(nick)
    if @reg[:users].has_key? nick
      return [nick, @reg[:users][nick]]
    else # maybe an alternative nickname?
      @reg[:users].each_pair do |main_nick, user|
        return [main_nick, user] if user[:alt].include? nick
      end
    end
    [nil, nil]
  end

  # convert item object to IRC string (with bold text, etc.)
  def item_to_s(item)
    str = "#{Bold + item.id.to_s + NormalText} - "
    if item.type == 'image'
      str << "#{item.mimetype} "
      str << "#{format_size item.size} "
    else
      str << "#{item.type} "
    end

    if item.title and not item.title.empty?
      str << "\"#{Bold + item.title + NormalText}\""
    end
    if item.source and not item.source.match /http/
      str << " #{Bold + item.source + NormalText}"
    end

    if item.tags and not item.tags.empty?
      str << " - tagged: #{(item.tags.map {|tag| tag.tagname}).join ', '}"
    end

    if item.type == 'image' or not item.source
      url = "#{@base_url}#{item.id}"
    else
      if item.source.match %r{youtube\.com/watch\?v=([^&]+)} 
        url = "http://youtu.be/#{$1}"
      else
        url = item.source
      end
    end

    str << " (#{Bold + url + NormalText})"

    str << " +#{item.upvote_count}"


    str
  end

  def format_size(size)
    units = %w{kb mb gb}
    unit = 'b'
    while size >= 1024.0
      unit = units.shift
      size /= 1024.0
    end
    "#{'%.2f' % size}#{unit}"
  end

  def push_history(channel, id)
    if not @reg[:history].has_key? channel
      @reg[:history][channel] = [ id ] 
    else
      @reg[:history][channel] << id 
    end
  end

  def colorize(string)
    # irc colorize markup *bold*
    string.gsub(%r{\*([^\*]+)\*}, Bold + '\\1' + NormalText)
  end

end

###############################################################################

plugin = ZeitgeistPlugin.new

plugin.map 'zg', 
           :action => 'cmd_main'

plugin.map 'zg auth [:email] [:api_secret]', 
           :action => 'cmd_auth',
           :private => true,
           :defaults => {:email => nil, :api_secret => nil}

plugin.map 'zg enable :option',
           :action => 'cmd_enable'

plugin.map 'zg disable :option',
           :action => 'cmd_disable'

plugin.map 'zg alt :alt_nick',
           :action => 'cmd_alt'

plugin.map 'zg test',
           :threaded => true, 
           :action => 'cmd_test'

plugin.map 'zg show :id', 
           :threaded => true, 
           :action => 'cmd_item_show'

plugin.map 'zg create :url [*tags]', 
           :defaults => {:tags => ''} ,
           :threaded => true, 
           :action => 'cmd_item_create' 

plugin.map 'zg delete :id', 
           :threaded => true, 
           :auth_path => 'del',
           :action => 'cmd_item_delete' 

plugin.map 'zg update :id *tags', 
           :threaded => true, 
           :action => 'cmd_item_update' 

plugin.map 'zg upvote [:remove] :id', 
           :threaded => true, 
           :action => 'cmd_item_upvote' 

plugin.map 'zg error [:channel]', 
           :threaded => true, 
           :action => 'cmd_error' 

# announce new item, this should be called remote
plugin.map 'zg announce :id', 
           :threaded => true, 
           :action => 'cmd_item_announce' 
