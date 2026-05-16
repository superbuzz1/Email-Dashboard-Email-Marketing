require 'rails_helper'

RSpec.describe 'Api::V1::Users', type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }
  let(:auth_headers)  { { 'Authorization' => %(Token token="#{account.authentication_token}") } }

  describe 'POST /api/v1/users' do
    let(:valid_params) do
      {
        user: { name: 'API User', email: 'api-user@example.com', tag_list: 'lead, new' },
        attributes: { phone: '+15551234', custom_key: 'custom_value' }
      }
    end

    it 'requires a valid authentication token' do
      post '/api/v1/users', params: valid_params
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an unknown token' do
      post '/api/v1/users', params: valid_params,
                            headers: { 'Authorization' => 'Token token="not-a-real-token"' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates a user scoped to the authenticated account' do
      expect {
        post '/api/v1/users', params: valid_params, headers: auth_headers
      }.to change { account.users.count }.by(1)
        .and change { other_account.users.count }.by(0)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['user']['email']).to eq('api-user@example.com')
      expect(body['user']['account_id']).to eq(account.id)
    end

    it 'persists arbitrary user_attributes from params[:attributes]' do
      post '/api/v1/users', params: valid_params, headers: auth_headers
      created = account.users.find_by(email: 'api-user@example.com')

      expect(created.user_attributes.pluck(:key, :value)).to match_array(
        [['phone', '+15551234'], ['custom_key', 'custom_value']]
      )
    end

    it 'returns 422 with errors when the user is invalid' do
      post '/api/v1/users', params: { user: { name: 'No Email' } }, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)).to have_key('errors')
    end

    it 'rejects duplicate emails within the same account' do
      create(:user, account: account, email: 'api-user@example.com')

      post '/api/v1/users', params: valid_params, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'allows the same email across different accounts' do
      create(:user, account: other_account, email: 'api-user@example.com')

      post '/api/v1/users', params: valid_params, headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /api/v1/users/add_tags' do
    let!(:existing) { create(:user, account: account, email: 'tagged@example.com') }

    it 'requires a valid token' do
      post '/api/v1/users/add_tags', params: { email: existing.email, tags: 'vip' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'adds tags to an existing user' do
      post '/api/v1/users/add_tags',
           params: { email: existing.email, tags: 'vip,beta' },
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(existing.reload.tag_list).to include('vip', 'beta')
    end

    it 'returns 422 when tags param is missing' do
      post '/api/v1/users/add_tags', params: { email: existing.email }, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['errors']).to include('tag param is missing')
    end

    it 'creates the user when the email is unknown to this account' do
      expect {
        post '/api/v1/users/add_tags',
             params: { email: 'brand-new@example.com', tags: 'fresh' },
             headers: auth_headers
      }.to change { account.users.count }.by(1)

      created = account.users.find_by(email: 'brand-new@example.com')
      expect(created.tag_list).to include('fresh')
    end

    it 'does not touch users belonging to other accounts' do
      other_user = create(:user, account: other_account, email: 'shared@example.com')

      post '/api/v1/users/add_tags',
           params: { email: 'shared@example.com', tags: 'vip' },
           headers: auth_headers

      expect(other_user.reload.tag_list).to be_empty
      expect(account.users.find_by(email: 'shared@example.com')).to be_present
    end
  end

  describe 'POST /api/v1/users/remove_tags' do
    let!(:existing) do
      user = create(:user, account: account, email: 'tagged@example.com')
      user.tag_list.add('vip', 'beta')
      user.save!
      user
    end

    it 'requires a valid token' do
      post '/api/v1/users/remove_tags', params: { email: existing.email, tags: 'vip' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'removes the specified tags' do
      post '/api/v1/users/remove_tags',
           params: { email: existing.email, tags: 'vip' },
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(existing.reload.tag_list).to contain_exactly('beta')
    end

    it 'returns 422 when tags param is missing' do
      post '/api/v1/users/remove_tags', params: { email: existing.email }, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['errors']).to include('tag param is missing')
    end
  end
end
