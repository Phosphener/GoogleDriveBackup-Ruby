require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/installed_app'
require 'google/api_client/auth/storage'
require 'google/api_client/auth/storages/file_store'
require 'fileutils'
require 'net/http'

##
# Bad security hack to get my SSL to work (or not work as the case may be)
require 'openssl'
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

##
# Variables needed to authorize and download from the user's
# google drive
FOLDER_ID           = '0B3ten22oqTp1fkY5dllVaTFMczZuRzdSdkZVcXlrMFhkNE1lZXpuT1'\
                      'BYWjJGWXZYN1JRR1k'
APPLICATION_NAME    = 'GoogleDriveBackupRuby'
CLIENT_SECRETS_PATH = 'client_secret.json'
CREDENTIALS_PATH    = File.join(Dir.home,
                                '.credentials',
                                'drive-quickstart.json')
SCOPE = 'https://www.googleapis.com/auth/drive/auth/drive.metadata.readonly'

##
# Google drive class that handles authentication of and
# downloading from a users google drive
class GoogleDriveDownloader
  FOLDER        = 'application/vnd.google-apps.folder'
  DOCUMENT      = 'application/vnd.google-apps.document'
  SPREADSHEET   = 'application/vnd.google-apps.spreadsheet'
  PRESENTATION  = 'application/vnd.google-apps.presentation'
  DOCUMENT_LINK = 'application/vnd.openxmlformats-officedocument'\
                  '.wordprocessingml.document'
  SHEETS_LINK   = 'application/vnd.openxmlformats-officedocument.spreadsheetml'\
                  '.sheet'
  PRES_LINK     = 'application/vnd.openxmlformats-officedocument'\
                  '.presentationml.presentation'
  ALLOWED_TYPES = [DOCUMENT, SPREADSHEET, PRESENTATION]

  # Authenticate and instantiate the google drive
  def initialize(app_name, credentials_path, client_secrets_path, scope)
    gda          = GoogleDriveAuthenticator.new(app_name,
                                                credentials_path,
                                                client_secrets_path,
                                                scope)
    @client      = gda.client
    @drive_api   = gda.drive_api
    @threads = []
    @semaphore = Mutex.new
  end

  ##
  # Google authentication class that handles authentication of a google
  # drive user
  class GoogleDriveAuthenticator
    attr_accessor :client, :drive_api
    def initialize(app_name, credentials_path, client_secrets_path, scope)
      # Initialize the API
      @client               = Google::APIClient.new(application_name: app_name)
      @client.authorization = authorize(credentials_path,
                                        client_secrets_path,
                                        scope)
      @drive_api = @client.discovered_api('drive', 'v2')
    end

    ##
    # Ensure valid credentials, either by restoring from the saved credentials
    # files or intitiating an OAuth2 authorization request via InstalledAppFlow.
    # If authorization is required, the user's default browser will be launched
    # to approve the request.
    #
    # @return [Signet::OAuth2::Client] OAuth2 credentials
    def authorize(credentials_path, client_secrets_path, scope)
      FileUtils.mkdir_p(File.dirname(credentials_path))
      file_store  = Google::APIClient::FileStore.new(credentials_path)
      storage     = Google::APIClient::Storage.new(file_store)
      auth        = storage.authorize
      check_auth_expiration auth, client_secrets_path, scope
      auth
    end

    # Checks authorization token expiration date and refreshes it if not there
    def check_auth_expiration(auth, client_secrets_path, scope)
      return false unless auth.nil? ||
                          (auth.expired? && auth.refresh_token.nil?)
      app_info  = Google::APIClient::ClientSecrets.load(client_secrets_path)
      flow      = Google::APIClient::InstalledAppFlow.new(
        client_id: app_info.client_id,
        client_secret: app_info.client_secret,
        scope: scope)
      auth = flow.authorize(storage)
      puts "Credentials saved to #{credentials_path}" unless auth.nil?
    end
  end

  # Backup the identified folder
  def backup_folder(folder_id, path)
    backup_folder_rec folder_id, path
    puts 'Progress:'
    @threads.each_with_index do |thread, i| # <- Finish all jobs
      thread.join
      print '#' if i % @threads.size / 10 == 1
    end
  end

  # Recursively download every file in a folder
  def backup_folder_rec(folder_id, path)
    results = @client.execute!(
      api_method: @drive_api.files.list,
      parameters: { q: "'#{folder_id}' in parents" })
    children = results.data.items
    # puts "Children: #{children.size}"
    # puts 'No Children found' if children.empty?
    download_children children, path
  end

  # Download files and make folders where necessary
  def download_children(children, path)
    children.each do |child|
      new_path = "#{path}/#{child.title}"
      backup_folder_rec child.id, new_path if child.mimeType == FOLDER
      download_if_allowed_child child, new_path
    end
  end

  # Download into new_path if is an allowed type
  def download_if_allowed_child(child, new_path)
    return false unless ALLOWED_TYPES.include? child.mimeType
    revisions = retrieve_revisions(child.id)
    puts "Downloading #{revisions.size} revisions for #{child.title}"\
         " (#{child.id}) in #{new_path}"
    FileUtils.mkdir_p new_path
    @semaphore.synchronize do
      @threads << Thread.new { download_revisions(child, revisions, new_path) }
    end
  end

  # Retrieve all revisions of a file
  def retrieve_revisions(file_id)
    api_result = @client.execute(
      api_method: @drive_api.revisions.list,
      parameters: { 'fileId' => file_id })
    if api_result.status == 200
      revisions = api_result.data
      return revisions.items
    else
      puts "An error occurred: #{result.data['error']['message']}"
    end
  end

  # Downlaod all revisions of a child
  def download_revisions(child, revisions, new_path)
    revisions.each do |revision|
      download_url = retrieve_download_url revision, child.mimeType
      dl            = @client.execute!(uri: download_url.to_s) # Download file
      save_revision child, revision, dl, new_path
    end
  end

  # Retrieve the download url of a revision
  def retrieve_download_url(revision, type)
    # Download from export links as document
    download_url = revision['exportLinks'][DOCUMENT_LINK] if
      type == DOCUMENT
    # Otherwise download from export links as spreadsheet
    download_url = revision['exportLinks'][SHEETS_LINK] if
      type == SPREADSHEET
    # Otherwise download from export links as presentation
    download_url = revision['exportLinks'][PRES_LINK] if
      type == PRESENTATION
    download_url
  end

  # Save the revision to disk in new_path
  def save_revision(child, revision, dl, new_path)
    modified_date = "#{revision['modifiedDate'].to_s.gsub(/:/, '_')}"
    output_file   = "#{new_path}/#{child.title}_"\
                    "#{modified_date}_"\
                    "#{revision['lastModifyingUserName']}"\
                    ".#{retrieve_download_url(revision, child.mimeType)[-4, 4]}"

    # Save downloaded file
    # puts "Creating #{child.title} revision: ID #{revision.id}"
    IO.binwrite output_file, dl.body
  end
end

gdd = GoogleDriveDownloader.new(APPLICATION_NAME,
                                CREDENTIALS_PATH,
                                CLIENT_SECRETS_PATH,
                                SCOPE)
gdd.backup_folder FOLDER_ID, 'Revisions'
puts '\nDone.'
