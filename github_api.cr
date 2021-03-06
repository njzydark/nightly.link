require "halite"
require "memory_cache"
require "jwt"

require "./cache_util"

alias InstallationId = Int64

abstract struct Token
  def to_s
    "token #{@token}"
  end
end

struct AppToken < Token
  def initialize(@token : String)
  end

  def to_s
    "Bearer #{@token}"
  end
end

struct UserToken < Token
  def initialize(@token : String)
  end
end

struct InstallationToken < Token
  include JSON::Serializable
  getter token : String

  def initialize(@token : String)
  end
end

struct OAuthToken < Token
  def initialize(@token : String)
  end
end

class GitHubAppAuth
  def initialize(@app_id : Int32, @pem_filename : String)
  end

  def jwt : AppToken
    @@jwt.fetch(@app_id, expires_in: 9.minutes) do
      AppToken.new(
        JWT.encode({
          iat: Time.utc.to_unix,                # issued at time
          exp: (Time.utc + 10.minutes).to_unix, # JWT expiration time (10 minute maximum)
          iss: @app_id,                         # GitHub App's identifier
        }, File.read(@pem_filename), JWT::Algorithm::RS256)
      )
    end
  end

  private def new_token(installation_id : InstallationId) : InstallationToken
    result = nil
    GitHub.post(
      "/app/installations/#{installation_id}/access_tokens",
      json: {permissions: {actions: "read"}},
      headers: {authorization: jwt}
    ) do |resp|
      resp.raise_for_status
      result = InstallationToken.from_json(resp.body_io)
    end
    result.not_nil!
  end

  def token(installation_id : InstallationId, *, new : Bool = false) : InstallationToken
    if new
      @@token.write(installation_id, new_token(installation_id), expires_in: 55.minutes)
    else
      @@token.fetch(installation_id, expires_in: 55.minutes) do
        new_token(installation_id)
      end
    end
  end

  @@jwt = MemoryCache(Int32, AppToken).new
  @@token = CleanedMemoryCache(InstallationId, InstallationToken).new
end

GitHub = Halite::Client.new do
  endpoint("https://api.github.com/")
  logging(skip_request_body: true, skip_response_body: true)
end

macro get_json_list(t, url, params = NamedTuple.new, max_items = 1000, **kwargs)
  %url : String? = {{url}}
  %max_items : Int32 = {{max_items}}
  %params = {per_page: %max_items}.merge({{params}})
  n = 0
  while %url
    %result = nil
    GitHub.get(%url, params: %params, {{**kwargs}}) do |resp|
      resp.raise_for_status
      %result = {{t}}.from_json(resp.body_io)
      %url = resp.links.try(&.["next"]?).try(&.target)
      %params = {per_page: %max_items}
    end
    %result.not_nil!{% if t.is_a?(Path) %}.{{t.id.underscore}}{% end %}.each do |x|
      yield x
      n += 1
      break if n >= %max_items
    end
    break if n >= %max_items
  end
end

struct Installations
  include JSON::Serializable
  property installations : Array(Installation)

  def self.for_user(token : UserToken, & : Installation ->)
    # https://docs.github.com/v3/apps#list-app-installations-accessible-to-the-user-access-token
    get_json_list(
      Installations, "user/installations",
      headers: {authorization: token}, max_items: 10
    )
  end

  def self.for_app(token : AppToken, since : Time? = nil, & : Installation ->)
    # https://docs.github.com/v3/apps#list-installations-for-the-authenticated-app
    params = {since: since && (since + 1.millisecond).to_rfc3339(fraction_digits: 3)}
    get_json_list(
      Array(Installation), "app/installations", params: params,
      headers: {authorization: token}, max_items: 100000
    )
  end
end

module RFC3339Converter
  def self.from_json(value : JSON::PullParser) : Time
    Time.parse_rfc3339(value.read_string)
  end
end

struct Installation
  include JSON::Serializable
  property id : InstallationId
  property account : Account
  @[JSON::Field(converter: RFC3339Converter)]
  property updated_at : Time

  def self.for_id(id : InstallationId, token : AppToken) : Installation
    # https://docs.github.com/v3/apps#get-an-installation-for-the-authenticated-app
    result = nil
    GitHub.get("app/installations/#{id}", headers: {authorization: token}) do |resp|
      resp.raise_for_status
      result = Installation.from_json(resp.body_io)
    end
    result.not_nil!
  end
end

struct Account
  include JSON::Serializable
  property login : String

  def self.for_oauth(token : OAuthToken) : Account
    # https://docs.github.com/v3/users#get-the-authenticated-user
    result = nil
    GitHub.get("user", headers: {authorization: token}) do |resp|
      resp.raise_for_status
      result = Account.from_json(resp.body_io)
    end
    result.not_nil!
  end
end

struct Repositories
  include JSON::Serializable
  property repositories : Array(Repository)

  cached_array def self.for_installation(installation_id : InstallationId, token : UserToken, & : Repository ->)
    # https://docs.github.com/v3/apps#list-repositories-accessible-to-the-user-access-token
    get_json_list(
      Repositories, "user/installations/#{installation_id}/repositories",
      headers: {authorization: token}, max_items: 300
    )
  end

  cached_array def self.for_installation(token : InstallationToken, & : Repository ->)
    # https://docs.github.com/v3/apps#list-repositories-accessible-to-the-app-installation
    get_json_list(
      Repositories, "installation/repositories",
      headers: {authorization: token}, max_items: 300
    )
  end
end

struct Repository
  include JSON::Serializable
  property full_name : String
  property? private : Bool
  property? fork : Bool
end

struct Workflows
  include JSON::Serializable
  property workflows : Array(Workflow)

  cached_array def self.for_repo(repo_owner : String, repo_name : String, token : InstallationToken | UserToken, & : Workflow ->)
    # https://docs.github.com/v3/actions#list-repository-workflows
    get_json_list(
      Workflows, "/repos/#{repo_owner}/#{repo_name}/actions/workflows",
      headers: {authorization: token}, max_items: 100
    )
  end
end

struct Workflow
  include JSON::Serializable
  property id : Int64
  property name : String
  property path : String
end

struct WorkflowRuns
  include JSON::Serializable
  property workflow_runs : Array(WorkflowRun)

  cached_array def self.for_repo(repo_owner : String, repo_name : String, token : InstallationToken | UserToken, max_items : Int32, & : WorkflowRun ->)
    # https://docs.github.com/v3/actions#list-workflow-runs-for-a-repository
    get_json_list(
      WorkflowRuns, "repos/#{repo_owner}/#{repo_name}/actions/runs",
      params: {event: "push", status: "success"},
      headers: {authorization: token}, max_items: max_items
    )
  end

  cached_array def self.for_workflow(repo_owner : String, repo_name : String, workflow : String, branch : String, token : InstallationToken | UserToken, max_items : Int32, & : WorkflowRun ->)
    # https://docs.github.com/v3/actions#list-workflow-runs
    get_json_list(
      WorkflowRuns, "repos/#{repo_owner}/#{repo_name}/actions/workflows/#{workflow}/runs",
      params: {branch: branch, event: "push", status: "success"},
      headers: {authorization: token}, max_items: max_items
    )
  end
end

struct WorkflowRun
  include JSON::Serializable
  property id : Int64
  property head_branch : String
  property workflow_id : Int64
  property check_suite_url : String
end

struct Artifacts
  include JSON::Serializable
  property artifacts : Array(Artifact)

  cached_array def self.for_run(repo_owner : String, repo_name : String, run_id : Int64, token : InstallationToken | UserToken, & : Artifact ->)
    # https://docs.github.com/v3/actions#list-workflow-run-artifacts
    get_json_list(
      Artifacts, "repos/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}/artifacts",
      headers: {authorization: token}, max_items: 100
    )
  end
end

struct Artifact
  include JSON::Serializable
  property id : Int64
  property name : String

  @@cache_zip_by_id = CleanedMemoryCache({String, String, Int64}, String).new

  def self.zip_by_id(repo_owner : String, repo_name : String, artifact_id : Int64, token : InstallationToken | UserToken) : String
    @@cache_zip_by_id.fetch({repo_owner, repo_name, artifact_id}, expires_in: 50.seconds) do
      GitHub.get(
        "repos/#{repo_owner}/#{repo_name}/actions/artifacts/#{artifact_id}/zip",
        headers: {authorization: token}
      ).tap(&.raise_for_status).headers["location"]
    end
  end
end
