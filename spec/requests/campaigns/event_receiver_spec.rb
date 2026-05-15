require 'rails_helper'

RSpec.describe 'POST /campaigns/event_receiver', type: :request do
  let(:account)        { create(:account) }
  let(:other_account)  { create(:account) }
  let(:template)       { create(:email_template, account: account) }
  let(:campaign)       { create(:campaign, account: account, email_template: template) }
  let(:user)           { create(:user, account: account) }
  let(:campaign_user)  { create(:campaign_user, campaign: campaign, user: user) }

  let(:json_headers) { { 'Content-Type' => 'application/json' } }

  def post_events(events)
    post '/campaigns/event_receiver', params: events.to_json, headers: json_headers
  end

  it 'is reachable without authentication' do
    post_events([])
    expect(response).to have_http_status(:no_content)
  end

  it 'updates status for the matched campaign_user' do
    post_events([{ campaign_user_id: campaign_user.id, event: 'delivered' }])

    expect(response).to have_http_status(:no_content)
    expect(campaign_user.reload.status).to eq('delivered')
  end

  it 'updates statuses for multiple events in one payload' do
    other_user      = create(:user, account: account)
    other_cu        = create(:campaign_user, campaign: campaign, user: other_user)

    post_events([
      { campaign_user_id: campaign_user.id, event: 'open' },
      { campaign_user_id: other_cu.id,      event: 'bounce' }
    ])

    expect(campaign_user.reload.status).to eq('open')
    expect(other_cu.reload.status).to eq('bounce')
  end

  it 'silently ignores unknown campaign_user ids' do
    post_events([{ campaign_user_id: 999_999, event: 'delivered' }])
    expect(response).to have_http_status(:no_content)
  end

  it 'ignores events with no campaign_user_id key' do
    original = campaign_user.status
    post_events([{ event: 'delivered' }])
    expect(response).to have_http_status(:no_content)
    expect(campaign_user.reload.status).to eq(original)
  end

  it 'crosses account boundaries by id (documents existing webhook contract)' do
    # The webhook trusts whatever campaign_user_id SendGrid sends, with no
    # account check. This spec pins that behavior so any future tightening
    # (e.g. signing the webhook, scoping by account) breaks here on purpose.
    foreign_template = create(:email_template, account: other_account)
    foreign_campaign = create(:campaign, account: other_account, email_template: foreign_template)
    foreign_user     = create(:user, account: other_account)
    foreign_cu       = create(:campaign_user, campaign: foreign_campaign, user: foreign_user)

    post_events([{ campaign_user_id: foreign_cu.id, event: 'unsubscribe' }])

    expect(foreign_cu.reload.status).to eq('unsubscribe')
  end

  it 'raises on malformed JSON bodies' do
    expect {
      post '/campaigns/event_receiver', params: 'not-json', headers: json_headers
    }.to raise_error(JSON::ParserError)
  end
end
