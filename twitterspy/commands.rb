require 'rubygems'
require 'base64'

require 'twitter'

module TwitterSpy
  module Commands

    class Help
      attr_accessor :short_help, :full_help

      def initialize(short_help)
        @short_help = @full_help = short_help
      end

      def to_s
        @short_help
      end
    end

    module CommandDefiner

      def all_cmds
        @@all_cmds ||= {}
      end

      def cmd(name, help=nil, &block)
        unless help.nil?
          all_cmds()[name.to_s] = TwitterSpy::Commands::Help.new help
        end
        define_method(name, &block)
      end

      def help_text(name, text)
        all_cmds()[name.to_s].full_help = text
      end

    end

    class CommandProcessor

      extend CommandDefiner

      def initialize(conn)
        @jabber = conn
      end

      def typing_notification(user)
        @jabber.client.send("<message
            from='#{Config::SCREEN_NAME}'
            to='#{user.jid}'>
            <x xmlns='jabber:x:event'>
              <composing/>
            </x></message>")
      end

      def dispatch(cmd, user, arg)
        typing_notification user
        if self.respond_to? cmd
          self.send cmd.to_sym, user, arg
        else
          if user.auto_post
            post user, "#{cmd} #{arg}"
          else
            out = ["I don't understand '#{cmd}'."]
            out << "Send 'help' for known commands."
            out << "If you intended this to be posted, see 'help autopost'"
            send_msg user, out.join("\n")
          end
        end
      end

      def send_msg(user, text)
        @jabber.deliver user.jid, text
      end

      cmd :help, "Get help for commands." do |user, arg|
        cmds = self.class.all_cmds()
        if arg.blank?
          out = ["Available commands:"]
          out << "Type `help somecmd' for more help on `somecmd'"
          out << ""
          out << cmds.keys.sort.map{|k| "#{k}\t#{cmds[k]}"}
          out << ""
          out << "The search is based on summize.  For options, see http://summize.com/operators"
          out << "Email questions, suggestions or complaints to dustin@sallings.org"
          send_msg user, out.join("\n")
        else
          h = cmds[arg]
          if h
            out = ["Help for `#{arg}'"]
            out << h.full_help
            send_msg user, out.join("\n")
          else
            send_msg user, "Topic #{arg} is unknown.  Type `help' for known commands."
          end
        end
      end

      cmd :version do |user, nothing|
        out = ["Running version #{TwitterSpy::Config::VERSION}"]
        out << "For the source and more info, see http://github.com/dustin/twitterspy"
        send_msg user, out.join("\n")
      end

      cmd :on, "Activate updates." do |user, nothing|
        change_user_active_state(user, true)
        send_msg user, "Marked you active."
      end

      cmd :off, "Disable updates." do |user, nothing|
        change_user_active_state(user, false)
        send_msg user, "Marked you inactive."
      end

      cmd :autopost, "Enable or disable autopost" do |user, arg|
        with_arg(user, arg, "Use 'off' or 'on' to disable or enable autoposting") do |a|
          newval = case arg.downcase
          when "on"
            true
          when "off"
            false
          else
            raise "Autopost must be set to on or off"
          end
          user.update_attributes(:auto_post => newval)
          send_msg user, "Autoposting is now #{newval ? 'on' : 'off'}"
        end
      end
      help_text :autopost, <<-EOF
Autopost allows you to post by sending any unknown command.
usage:  'autopost on' or 'autopost off'

When autopost is on, any message that doesn't look like a command is posted.
Note that the 'post' command still exists in case you want to post something
that looks like a command.
EOF

      cmd :top10 do |user, arg|
        query = <<-EOF
select t.query, count(*) as watchers
  from tracks t join user_tracks ut on (t.id = ut.track_id)
  group by t.query
  order by watchers desc, query
  limit 10
EOF
        top = repository(:default).adapter.query query
        out = ["Top 10 most tracked topics:"]
        out << ""
        top.each do |row|
          out << "#{row['t.query']} (#{row['watchers']} watchers)"
        end
        send_msg user, out.join("\n")
      end

      cmd :track, "Track a topic (summize query string)" do |user, arg|
        with_arg(user, arg) do |a|
          user.track a
          send_msg user, "Tracking #{a}"
        end
      end
      help_text :track, <<-EOF
Track gives you all of the power of summize queries periodically delivered to your IM client.
Example queries:

track iphone
track iphone OR android
track iphone android

See http://summize.com/operators for details on what all you can do.
EOF

      cmd :untrack, "Stop tracking a topic" do |user, arg|
        with_arg(user, arg) do |a|
          if user.untrack a
            send_msg user, "Stopped tracking #{a}"
          else
            send_msg user, "Didn't stop tracking #{a} (are you sure you were tracking it?)"
          end
        end
      end
      help_text :untrack, <<-EOF
Untrack tells twitterspy to stop tracking the given query.
Examples:

untrack iphone
untrack iphone OR android
untrack iphone android
EOF

      cmd :tracks, "List your tracks." do |user, arg|
        tracks = user.tracks.map{|t| t.query}.sort
        send_msg user, "Tracking #{tracks.size} topics\n" + tracks.join("\n")
      end

      cmd :search, "Perform a sample search (but do not track)" do |user, arg|
        with_arg(user, arg) do |query|
          TwitterSpy::Threading::IN_QUEUE << Proc.new do
            summize_client = Summize::Client.new TwitterSpy::Config::USER_AGENT
            res = summize_client.query query, :rpp => 2
            out = ["Results from your query:"]
            res.each do |r|
              out << "#{r.from_user}: #{r.text}"
            end
            send_msg user, out.join("\n\n")
          end
        end
      end

      cmd :whois, "Find out who a particular user is." do |user, arg|
        twitter_call user, arg, "For whom are you looking?" do |twitter, username|
          begin
            u = twitter.user username.strip
            out = ["#{username} is #{u.name.blank? ? 'Someone' : u.name} from #{u.location.blank? ? 'Somewhere' : u.location}"]
            out << "Most recent tweets:"
            summize_client = Summize::Client.new TwitterSpy::Config::USER_AGENT
            res = summize_client.query "from:#{username.strip}", :rpp => 3
            # Get the first status from the twitter response (in case none is indexed)
            res.each_with_index do |r, i|
              out << "\n#{i+1}) #{r.text}"
            end
            out << "\nhttp://twitter.com/#{username.strip}"
            send_msg user, out.join("\n")
          rescue StandardError, Interrupt
            puts "Unable to do a whois:  #{$!}\n" + $!.backtrace.join("\n\t")
            $stdout.flush
            send_msg user, "Unable to get information for #{username}"
          end
        end
      end

      cmd :twlogin, "Set your twitter username and password (use at your own risk)" do |user, arg|
        with_arg(user, arg, "You must supply a username and password") do |up|
          u, p = up.strip.split(/\s+/, 2)
          TwitterSpy::Threading::TWIT_QUEUE << Proc.new do
            twitter = Twitter::Base.new u, p
            begin
              twitter.verify_credentials
              user.update_attributes(:username => u, :password => Base64.encode64(p).strip, :next_scan => DateTime.now)
              send_msg user, "Your credentials have been verified and saved.  Thanks."
            rescue StandardError, Interrupt
              puts "Unable to verify credentials:  #{$!}\n" + $!.backtrace.join("\n\t")
              $stdout.flush
              send_msg user, "Unable to verify your credentials.  They're either wrong or twitter is broken."
            end
          end
        end
      end
      help_text :twlogin, <<-EOF
Provide login credentials for twitter.
NOTE: Giving out your credentials is dangerous.  We will try to keep them safe, but we can't make any promises.
Example usage:

twlogin mytwittername myr4a11yk0mp13xp455w0rd
EOF

      cmd :twlogout, "Discard your twitter credentials" do |user, arg|
        user.update_attributes(:username => nil, :password => nil)
        send_msg user, "You have been logged out."
      end

      cmd :status do |user, arg|
        out = ["Jid:  #{user.jid}"]
        out << "Jabber Status:  #{user.status}"
        out << "TwitterSpy state:  #{user.active ? 'Active' : 'Not Active'}"
        if logged_in?(user)
          out << "Logged in for twitter API services as #{user.username}"
        else
          out << "You're not logged in for twitter API services."
        end
        out << "You are currently tracking #{user.tracks.size} topics."
        send_msg user, out.join("\n")
      end

      cmd :post, "Post a message to twitter." do |user, arg|
        twitter_call user, arg, "You need to actually tell me what to post" do |twitter, message|
          begin
            rv = twitter.post message, :source => 'twitterspy'
            url = "http://twitter.com/#{user.username}/statuses/#{rv.id}"
            send_msg user, ":) Your message has been posted to twitter: " + url
          rescue StandardError, Interrupt
            puts "Failed to post to twitter:  #{$!}\n" + $!.backtrace.join("\n\t")
            $stdout.flush
            send_msg user, ":( Failed to post your message.  Your password may be wrong, or twitter may be broken."
          end
        end
      end

      cmd :follow, "Follow a user" do |user, arg|
        twitter_call user, arg, "Whom would you like to follow?" do |twitter, username|
          begin
            twitter.create_friendship username
            send_msg user, ":) Now following #{username}"
          rescue StandardError, Interrupt
            puts "Failed to follow a user:  #{$!}\n" + $!.backtrace.join("\n\t")
            $stdout.flush
            send_msg user, ":( Failed to follow #{username} #{$!}"
          end
        end
      end

      cmd :leave, "Leave (stop following) a user" do |user, arg|
        twitter_call user, arg, "Whom would you like to leave?" do |twitter, username|
          begin
            twitter.destroy_friendship username
            send_msg user, ":) No longer following #{username}"
          rescue StandardError, Interrupt
            puts "Failed to stop following a user:  #{$!}\n" + $!.backtrace.join("\n\t")
            $stdout.flush
            send_msg user, ":( Failed to leave #{username} #{$!}"
          end
        end
      end

      cmd :watch_friends, "Enable or disable watching friends." do |user, arg|
        twitter_call user, arg, "Please specify 'on' or 'off'" do |twitter, val|
          case val
          when "on"
            begin
              item = twitter.timeline.first
              user.update_attributes(:friend_timeline_id => item.id.to_i)
              send_msg user, "Watching messages from everyone you follow after ``#{item.text}'' from @#{item.user.screen_name}"
            rescue
              puts "Failed to do initial friend stuff lookup for user: #{$!}\n" + $!.backtrace.join("\n\t")
              $stdout.flush
              send_msg user, ":( Failed to lookup your public timeline"
            end
          when "off"
            user.update_attributes(:friend_timeline_id => nil)
            send_msg user, "No longer watching your friends."
          else
            send_msg user, "Watch value must be 'off' or 'on'"
          end
        end
      end
      help_text :watch_friends, <<-EOF
Enable or disable watching friends.

  watch_friends on

floods you with IMs as people you're following tweet.

  watch_friends off

gives you a more relaxing day.
EOF

      cmd :lang, "Set your language." do |user, arg|
        arg = nil if arg && arg.strip == ""
        if arg && arg.size != 2
          send_msg user, "Language should be a 2-digit country code."
          return
        end

        user.update_attributes(:language => arg)
        if arg
          send_msg user, "Set your language to #{arg}"
        else
          send_msg user, "Unset your language."
        end
      end
      help_text :lang, <<-EOF
Set or clear your language preference.
With no argument, your language preference is cleared and you can receive tweets in any language.
Otherwise, supply a 2 letter ISO country code to restrict tracks to your favorite language.

Example: to set your language to English so only English tweets are returned from tracks:

lang en

Example: to unset your language:

lang
EOF

      private

      def logged_in?(user)
        !(user.username.blank? || user.password.blank?)
      end

      def twitter_call(user, arg, missing_text="Argument needed.", &block)
        if !logged_in?(user)
          send_msg user, "I don't know your username or password.  Use twlogin to set creds."
          return
        end

        password = Base64.decode64 user.password

        with_arg(user, arg, missing_text) do |a|
          TwitterSpy::Threading::TWIT_QUEUE << Proc.new do
            password = Base64.decode64 user.password
            twitter = Twitter::Base.new user.username, password
            yield twitter, a
          end
        end
      end

      def with_arg(user, arg, missing_text="Please supply a summize query")
        if arg.nil? || arg.strip == ""
          send_msg user, missing_text
        else
          yield arg.strip
        end
      end

      def change_user_active_state(user, to)
        if user.active != to
          user.active = to
          user.availability_changed
          user.save
        end
      end

    end # CommandProcessor

  end
end
