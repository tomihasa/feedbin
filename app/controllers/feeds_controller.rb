class FeedsController < ApplicationController

  before_action :correct_user, only: :update
  skip_before_action :authorize, only: [:push]
  skip_before_action :verify_authenticity_token, only: [:push]

  def update
    @user = current_user
    @mark_selected = true

    @feed = Feed.find(params[:id])
    @feed.tag(params[:feed][:tag_list], @user)

    if params[:no_response].present?
      head :ok
    else
      get_feeds_list
    end

  end

  def rename
    @user = current_user
    @subscription = @user.subscriptions.where(feed_id: params[:feed_id]).first!
    title = params[:feed][:title]
    @subscription.title = title.empty? ? nil : title
    @subscription.save
  end

  def view_unread
    update_view_mode('view_unread')
  end

  def view_starred
    update_view_mode('view_starred')
  end

  def view_all
    update_view_mode('view_all')
  end

  def auto_update
    get_feeds_list
  end

  def push
    feed = Feed.find(params[:id])
    secret = Push::hub_secret(feed.id)

    if request.get?
      response = ""
      if [feed.self_url, feed.feed_url].include?(params['hub.topic']) && secret == params['hub.verify_token']
        if params['hub.mode'] == 'subscribe'
          Librato.increment 'push.subscribe'
          feed.update_attributes(push_expiration: Time.now + (params['hub.lease_seconds'].to_i/2).seconds)
          response = params['hub.challenge']
          status = :ok
        elsif params['hub.mode'] == 'unsubscribe'
          Librato.increment 'push.unsubscribe'
          feed.update_attributes(push_expiration: nil)
          response = params['hub.challenge']
          status = :ok
        end
      else
        SelfUrl.perform_async(feed.id)
        status = :not_found
      end
      render plain: response, status: status
    else
      if feed.subscriptions_count > 0
        body = request.raw_post.force_encoding("UTF-8")
        signature = OpenSSL::HMAC.hexdigest('sha1', secret, body)
        if request.headers['HTTP_X_HUB_SIGNATURE'] == "sha1=#{signature}"
          Sidekiq::Client.push_bulk(
            'args'  => [[feed.id, feed.feed_url, {xml: body}]],
            'class' => 'FeedRefresherFetcherCritical',
            'queue' => 'feed_refresher_fetcher_critical',
            'retry' => false
          )
          Librato.increment 'entry.push'
        else
          Honeybadger.notify(error_class: "PuSH", error_message: "PuSH Invalid Signature", parameters: params)
        end
      else
        uri = URI(ENV['PUSH_URL'])
        options = {
          push_callback: Rails.application.routes.url_helpers.push_feed_url(feed, protocol: uri.scheme, host: uri.host),
          hub_secret: secret,
          push_mode: "unsubscribe"
        }
        Sidekiq::Client.push_bulk(
          'args'  => [[feed.id, feed.feed_url, options]],
          'class' => 'FeedRefresherFetcher',
          'queue' => 'feed_refresher_fetcher',
          'retry' => false
        )
      end
      head :ok
    end

  end

  def toggle_updates
    @user = current_user
    subscription = @user.subscriptions.where(feed_id: params[:id]).take!
    subscription.toggle!(:show_updates)
    if params.has_key?(:inline)
      @delay = false
      if !@user.setting_on?(:update_message_seen)
        @user.update_message_seen = '1'
        @user.save
        @delay = true
      end
    else
      head :ok
    end
  end

  def update_styles
    user = current_user
    @feed_ids = user.subscriptions.where(show_updates: false).pluck(:feed_id)
  end

  def search
    @user = current_user
    @feeds = FeedFinder.new(params[:q]).create_feeds!
    @feeds.map(&:priority_refresh)
  rescue
    @feeds = nil
  end

  private

  def update_view_mode(view_mode)
    @user = current_user
    @view_mode = view_mode
    @user.update_attributes(view_mode: @view_mode)
    head :ok
  end

  def correct_user
    unless current_user.subscribed_to?(params[:id])
      render_404
    end
  end

end
