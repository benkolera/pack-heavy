defmodule Packheavy.Accounts.User do
  use Ash.Resource,
    otp_app: :packheavy,
    domain: Packheavy.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource Packheavy.Accounts.Token
      signing_secret Packheavy.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      # Password strategy is dev/test only. The prod release is built
      # with MIX_ENV=prod, so this branch is skipped at compile time
      # and the password DSL never lands in the release — there is no
      # /sign-in form, no `register_with_password` action, no way to
      # set hashed_password from the running app. Prod auth is Auth0
      # → Google only.
      if Mix.env() in [:dev, :test] do
        password :password do
          identity_field :email
        end
      end

      # Auth0-fronted Google SSO. Registration is enabled so the very
      # first sign-in creates the user; the tenant's post-login
      # allowlist Action (configured from packheavy:allowedEmails in
      # the Pulumi stack) gates which addresses can ever land here.
      oauth2 :auth0 do
        client_id Packheavy.Secrets
        client_secret Packheavy.Secrets
        base_url Packheavy.Secrets
        redirect_uri Packheavy.Secrets
        authorize_url fn _, _ -> {:ok, "/authorize"} end
        token_url fn _, _ -> {:ok, "/oauth/token"} end
        user_url fn _, _ -> {:ok, "/userinfo"} end
        authorization_params scope: "openid profile email"
        register_action_name :register_with_auth0
        # Disabled because:
        #   1. The password strategy only exists in dev/test builds.
        #   2. The Auth0 post-login allowlist Action (allowedEmails)
        #      is the actual takeover prevention — only the addresses
        #      on that list can ever produce a successful login.
        # The default-on guard would require a confirmation add-on on
        # the password strategy, which is overkill for a single-user,
        # dev-only password path.
        prevent_hijacking? false
      end
    end
  end

  postgres do
    table "users"
    repo Packheavy.Repo
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get? true
      argument :email, :ci_string, allow_nil?: false
      filter expr(email == ^arg(:email))
    end

    create :register_with_auth0 do
      description "Upsert-by-email registration triggered by an Auth0 OAuth callback"
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_email

      change AshAuthentication.GenerateTokenChange

      change fn changeset, _ctx ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)
        Ash.Changeset.change_attribute(changeset, :email, user_info["email"])
      end
    end

    update :update_profile do
      description "Update the current user's profile fields"

      accept [
        :name,
        :phone,
        :satellite_sms,
        :location_tracker_url,
        :location_tracker_password,
        :default_hiker_weight_kg,
        :default_hiker_notes
      ]
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # Reads of self (e.g. profile page reload) and the profile update
    # action both require the actor to be the same user.
    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_profile) do
      authorize_if expr(id == ^actor(:id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    # Nullable so Auth0-only users (no local password) can exist.
    # Password strategy still validates presence at sign-in time.
    attribute :hashed_password, :string do
      allow_nil? true
      sensitive? true
    end

    # Profile fields. These provide the defaults that get copied into
    # the leader TripHiker record at trip-create time. Editing them
    # later doesn't retroactively rewrite past trips' hikers.
    attribute :name, :string, public?: true
    attribute :phone, :string, public?: true
    attribute :satellite_sms, :string, public?: true
    attribute :location_tracker_url, :string, public?: true

    attribute :location_tracker_password, :string do
      public? true
      sensitive? true
    end

    attribute :default_hiker_weight_kg, :decimal, public?: true
    attribute :default_hiker_notes, :string, public?: true
  end

  identities do
    identity :unique_email, [:email]
  end
end
