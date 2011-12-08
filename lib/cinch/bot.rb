# -*- coding: utf-8 -*-
require 'socket'
require "thread"
require "ostruct"
require "cinch/rubyext/module"
require "cinch/rubyext/string"
require "cinch/rubyext/infinity"

require "cinch/exceptions"

require "cinch/handler"
require "cinch/helpers"
require "cinch/logger_list"
require "cinch/logger/logger"
require "cinch/logger/null_logger"
require "cinch/logger/formatted_logger"
require "cinch/syncable"
require "cinch/message"
require "cinch/message_queue"
require "cinch/irc"
require "cinch/target"
require "cinch/channel"
require "cinch/user"
require "cinch/constants"
require "cinch/callback"
require "cinch/ban"
require "cinch/mask"
require "cinch/isupport"
require "cinch/plugin"
require "cinch/pattern"
require "cinch/mode_parser"
require "cinch/handler_list"
require "cinch/cached_list"
require "cinch/channel_list"
require "cinch/user_list"
require "cinch/plugin_list"
require "cinch/timer"
require "cinch/formatting"

require "cinch/configuration"
require "cinch/bot_configuration"
require "cinch/plugins_configuration"
require "cinch/ssl_configuration"
require "cinch/timeouts_configuration"

module Cinch
  # @attr nick
  # @attr modes
  # @attr logger
  # @version 2.0.0
  class Bot < User
    include Helpers


    # @return [BotConfiguration]
    # @version 1.2.0
    attr_reader :config

    # The underlying IRC connection
    #
    # @return [IRC]
    attr_reader :irc

    # The logger list containing all loggers
    #
    # @return [LoggerList]
    # @since 2.0.0
    attr_accessor :loggers

    # @return [Array<Channel>] All channels the bot currently is in
    attr_reader :channels

    # @return [String] the bot's hostname
    attr_reader :host

    # @return [Mask]
    attr_reader :mask

    # @return [String]
    attr_reader :user

    # @return [String]
    attr_reader :realname

    # @return [Time]
    attr_reader :signed_on_at

    # @return [PluginList] All registered plugins
    # @version 1.2.0
    attr_reader :plugins

    # @return [Boolean] whether the bot is in the process of disconnecting
    attr_reader :quitting

    # @return [UserList] All {User users} the bot knows about.
    # @since 1.1.0
    # TODO maybe call this :users?
    attr_reader :user_list

    # @return [ChannelList] All {Channel channels} the bot knows about.
    # @since 1.1.0
    #TODO maybe call this :channels?
    attr_reader :channel_list

    # @return [PluginList] All loaded plugins.
    # @version 1.2.0
    attr_reader :plugins

    # @return [Boolean]
    # @api private
    attr_accessor :last_connection_was_successful

    # @return [Callback]
    # @api private
    attr_reader :callback

    # All registered handlers.
    #
    # @return [HandlerList]
    # @see HandlerList
    # @since 2.0.0
    attr_reader :handlers

    # All modes set for the bot.
    #
    # @return [Array<String>]
    # @since 2.0.0
    attr_reader :modes

    # @group Helper methods

    # Define helper methods in the context of the bot.
    #
    # @yield Expects a block containing method definitions
    # @return [void]
    def helpers(&b)
      @callback.instance_eval(&b)
    end

    # Since Cinch uses threads, all handlers can be run
    # simultaneously, even the same handler multiple times. This also
    # means, that your code has to be thread-safe. Most of the time,
    # this is not a problem, but if you are accessing stored data, you
    # will most likely have to synchronize access to it. Instead of
    # managing all mutexes yourself, Cinch provides a synchronize
    # method, which takes a name and block.
    #
    # Synchronize blocks with the same name share the same mutex,
    # which means that only one of them will be executed at a time.
    #
    # @param [String, Symbol] name a name for the synchronize block.
    # @return [void]
    # @yield
    #
    # @example
    #    configure do |c|
    #      …
    #      @i = 0
    #    end
    #
    #    on :channel, /^start counting!/ do
    #      synchronize(:my_counter) do
    #        10.times do
    #          val = @i
    #          # at this point, another thread might've incremented :i already.
    #          # this thread wouldn't know about it, though.
    #          @i = val + 1
    #        end
    #      end
    #    end
    def synchronize(name, &block)
      # Must run the default block +/ fetch in a thread safe way in order to
      # ensure we always get the same mutex for a given name.
      semaphore = @semaphores_mutex.synchronize { @semaphores[name] }
      semaphore.synchronize(&block)
    end

    # @endgroup

    # @group Events &amp; Plugins

    # Registers a handler.
    #
    # @param [String, Symbol, Integer] event the event to match. Available
    #   events are all IRC commands in lowercase as symbols, all numeric
    #   replies, and the following:
    #
    #     - :channel (a channel message)
    #     - :private (a private message)
    #     - :message (both channel and private messages)
    #     - :error   (handling errors, use a numeric error code as `match`)
    #     - :ctcp    (ctcp requests, use a ctcp command as `match`)
    #     - :action  (actions, aka /me)
    #
    # @param [Regexp, String, Integer] match every message of the
    #   right event will be checked against this argument and the event
    #   will only be called if it matches
    #
    # @yieldparam [String] *args each capture group of the regex will
    #   be one argument to the block. It is optional to accept them,
    #   though
    #
    # @return [Array<Handler>] The handlers that have been registered
    def on(event, regexps = [], *args, &block)
      regexps = [*regexps]
      regexps = [//] if regexps.empty?

      event = event.to_sym

      handlers = []

      regexps.each do |regexp|
        pattern = case regexp
                 when Pattern
                   regexp
                 when Regexp
                   Pattern.new(nil, regexp, nil)
                 else
                   if event == :ctcp
                     Pattern.new(/^/, /#{Regexp.escape(regexp.to_s)}(?:$| .+)/, nil)
                   else
                     Pattern.new(/^/, /#{Regexp.escape(regexp.to_s)}/, /$/)
                   end
                 end
        @loggers.debug "[on handler] Registering handler with pattern `#{pattern.inspect}`, reacting on `#{event}`"
        handler = Handler.new(self, event, pattern, args, &block)
        handlers << handler
        @handlers.register(handler)
      end

      return handlers
    end

    # @endgroup
    # @group Bot Control

    # This method is used to set a bot's options. It indeed does
    # nothing else but yielding {Bot#config}, but it makes for a nice DSL.
    #
    # @yieldparam [Struct] config the bot's config
    # @return [void]
    def configure
      yield @config
    end

    # Disconnects from the server.
    #
    # @param [String] message The quit message to send while quitting
    # @return [void]
    def quit(message = nil)
      @quitting = true
      command = message ? "QUIT :#{message}" : "QUIT"
      @irc.send command
    end

    # Connects the bot to a server.
    #
    # @param [Boolean] plugins Automatically register plugins from
    #   `@config.plugins.plugins`?
    # @return [void]
    def start(plugins = true)
      @reconnects = 0
      @plugins.register_plugins(@config.plugins.plugins) if plugins

      begin
        @user_list.each do |user|
          user.in_whois = false
          user.unsync_all
        end # reset state of all users

        @channel_list.each do |channel|
          channel.unsync_all
        end # reset state of all channels

        @loggers.info "Connecting to #{@config.server}:#{@config.port}"
        @irc = IRC.new(self)
        @irc.start

        if @config.reconnect && !@quitting
          # double the delay for each unsuccesful reconnection attempt
          if @last_connection_was_successful
            @reconnects = 0
            @last_connection_was_successful = false
          else
            @reconnects += 1
          end

          # Sleep for a few seconds before reconnecting to prevent being
          # throttled by the IRC server
          wait = 2**@reconnects
          wait = @config.max_reconnect_delay if wait > @config.max_reconnect_delay
          @loggers.info "Waiting #{wait} seconds before reconnecting"
          sleep wait
        end
      end while @config.reconnect and not @quitting
    end

    # @endgroup
    # @group Channel Control

    # Join a channel.
    #
    # @param [String, Channel] channel either the name of a channel or a {Channel} object
    # @param [String] key optionally the key of the channel
    # @return [void]
    # @see Channel#join
    def join(channel, key = nil)
      Channel(channel).join(key)
    end

    # Part a channel.
    #
    # @param [String, Channel] channel either the name of a channel or a {Channel} object
    # @param [String] reason an optional reason/part message
    # @return [void]
    # @see Channel#part
    def part(channel, reason = nil)
      Channel(channel).part(reason)
    end

    # @endgroup

    # @return [Boolean] True if the bot reports ISUPPORT violations as
    #   exceptions.
    def strict?
      @config.strictness == :strict
    end

    # @yield
    def initialize(&b)
      @loggers = LoggerList.new
      @loggers << Logger::FormattedLogger.new($stderr)
      @config = BotConfiguration.new
      @handlers = HandlerList.new
      @semaphores_mutex = Mutex.new
      @semaphores = Hash.new { |h,k| h[k] = Mutex.new }
      @callback = Callback.new(self)
      @channels = []
      @quitting = false
      @modes    = []

      @user_list = UserList.new(self)
      @channel_list = ChannelList.new(self)
      @plugins = PluginList.new(self)

      instance_eval(&b) if block_given?

      join_lambda = lambda { @config.channels.each { |channel| Channel(channel).join }}
      if @config.delay_joins.is_a?(Symbol)
        handlers = on(@config.delay_joins) {
          handlers.each { |handler| handler.unregister }
          join_lambda.call
        }
      else
        Timer.new(self, interval: @config.delay_joins, shots: 1) do
          join_lambda.call
        end
      end
    end

    # @since 2.0.0
    def bot
      self
    end

    # Sets a mode on the bot.
    #
    # @param [String] mode
    # @return [void]
    # @since 2.0.0
    # @see Bot#modes
    # @see Bot#unset_mode
    def set_mode(mode)
      @irc.send "MODE #{nick} +#{mode}"
    end

    # Unsets a mode on the bot.
    #
    # @param [String] mode
    # @return [void]
    # @since 2.0.0
    def unset_mode(mode)
      @irc.send "MODE #{nick} -#{mode}"
    end

    # @since 2.0.0
    def modes=(modes)
      @modes.each do |mode|
        unset_mode(mode)
      end

      modes.each do |mode|
        set_mode(mode)
      end
    end

    # Used for updating the bot's nick from within the IRC parser.
    #
    # @param [String] nick
    # @api private
    # @return [void]
    def set_nick(nick)
      @nick = nick
    end

    # The bot's nickname.
    # @overload nick=(new_nick)
    #   @raise [Exceptions::NickTooLong] Raised if the bot is
    #     operating in {#strict? strict mode} and the new nickname is
    #     too long
    #   @return [String]
    # @overload nick
    #   @return [String]
    # @return [String]
    def nick
      @nick
    end

    def nick=(new_nick)
      if new_nick.size > @irc.isupport["NICKLEN"] && strict?
        raise Exceptions::NickTooLong, new_nick
      end
      @config.nick = new_nick
      @irc.send "NICK #{new_nick}"
    end

    # Try to create a free nick, first by cycling through all
    # available alternatives and then by appending underscores.
    #
    # @param [String] base The base nick to start trying from
    # @api private
    # @return String
    # @since 2.0.0
    def generate_next_nick!(base = nil)
      nicks = @config.nicks || []

      if base
        # if `base` is not in our list of nicks to try, assume that it's
        # custom and just append an underscore
        if !nicks.include?(base)
          new_nick =  base + "_"
        else
          # if we have a base, try the next nick or append an
          # underscore if no more nicks are left
          new_index = nicks.index(base) + 1
          if nicks[new_index]
            new_nick = nicks[new_index]
          else
            new_nick = base + "_"
          end
        end
      else
        # if we have no base, try the first possible nick
        new_nick = @config.nicks ? @config.nicks.first : @config.nick
      end

      @config.nick = new_nick
    end

    # @return [Boolean] True if the bot is using SSL to connect to the
    #   server.
    def secure?
      @config[:ssl] == true || (@config[:ssl].is_a?(Hash) && @config[:ssl][:use])
    end
    alias_method :secure, :secure?

    # @return [false] Always returns `false`.
    def unknown?
      false
    end
    alias_method :unknown, :unknown?

    def online?
      true
    end
    alias_method :online, :online?
  end
end
