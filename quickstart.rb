require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/installed_app'
require 'google/api_client/auth/storage'
require 'google/api_client/auth/storages/file_store'
require 'fileutils'
require 'net/http'

#Bad security hack to get my SSL to work (or not work as the case may be)
require 'openssl'
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

#Variables needed to authorize and download from the user's google drive
FOLDER_ID           = '0B3ten22oqTp1fkY5dllVaTFMczZuRzdSdkZVcXlrMFhkNE1lZXpuT1BYWjJGWXZYN1JRR1k'
APPLICATION_NAME    = 'GoogleDriveBackupRuby'
CLIENT_SECRETS_PATH = 'client_secret.json'
CREDENTIALS_PATH    = File.join(Dir.home, '.credentials',
                             "drive-quickstart.json")
SCOPE = 'https://www.googleapis.com/auth/drive/auth/drive.metadata.readonly'

#Google drive class that handles authentication of and downloading from a users google drive
class GoogleDrive
  FOLDER        = 'application/vnd.google-apps.folder'
  DOCUMENT      = 'application/vnd.google-apps.document'
  SPREADSHEET   = 'application/vnd.google-apps.spreadsheet'
  PRESENTATION  = 'application/vnd.google-apps.presentation'
  DOCUMENT_LINK = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  SHEETS_LINK   = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  PRES_LINK     = 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
  ALLOWED_TYPES = [DOCUMENT, SPREADSHEET, PRESENTATION]
  #DRAWING      = 'application/vnd.google-apps.drawing'
  
  def initialize app_name, credentials_path, client_secrets_path, scope
    # Initialize the API
    @client               = Google::APIClient.new(:application_name => app_name)
    @client.authorization = authorize app_name, credentials_path, client_secrets_path, scope
    #puts "Title \t ID \t Preferred"
    #client.discovered_apis.each do |gapi| 
    #  puts "#{gapi.title} \t #{gapi.id} \t #{gapi.preferred}"
    #end
    @drive_api = @client.discovered_api('drive', 'v2')
  end

  ##
  # Ensure valid credentials, either by restoring from the saved credentials
  # files or intitiating an OAuth2 authorization request via InstalledAppFlow.
  # If authorization is required, the user's default browser will be launched
  # to approve the request.
  #
  # @return [Signet::OAuth2::Client] OAuth2 credentials
  def authorize app_name, credentials_path, client_secrets_path, scope
    FileUtils.mkdir_p(File.dirname(credentials_path))

    file_store  = Google::APIClient::FileStore.new(credentials_path)
    storage     = Google::APIClient::Storage.new(file_store)
    auth        = storage.authorize

    if auth.nil? || (auth.expired? && auth.refresh_token.nil?)
      app_info  = Google::APIClient::ClientSecrets.load(client_secrets_path)
      flow      = Google::APIClient::InstalledAppFlow.new({
        :client_id => app_info.client_id,
        :client_secret => app_info.client_secret,
        :scope => scope})
      auth = flow.authorize(storage)
      puts "Credentials saved to #{credentials_path}" unless auth.nil?
    end
    auth
  end

  # Recursively ownload every file in a folder
  def download_revisions folder_id, path
    results = @client.execute!(
      :api_method => @drive_api.children.list,
      :parameters => {  :maxResults => 1000,
                        :folderId   => folder_id })
    puts "Children: #{results.data.items.size}"
    puts "No Children found" if results.data.items.empty?

    results.data.items.each do |child|

      file = @client.execute!(
        :api_method => @drive_api.files.get,
        :parameters => { :fileId => child.id })
      file = file.data
      new_path = "#{path}/#{file.title}"

      if file.mimeType == FOLDER
        puts 'Creating folder: '+new_path
        FileUtils::mkdir_p new_path
        download_revisions child.id, new_path

      #Don't download if not one of these
      elsif ALLOWED_TYPES.include? file.mimeType
        revisions = retrieve_revisions(@client, file.id)
        puts "Downloading #{revisions.size} revisions for #{file.title} in #{new_path}"
        FileUtils::mkdir_p new_path
        revisions.each do |revision|
          # Download from export links as document
          download_url = revision['exportLinks'][DOCUMENT_LINK] if revision.mimeType == DOCUMENT
          # Otherwise download from export links as spreadsheet
          download_url = revision['exportLinks'][SHEETS_LINK] if revision.mimeType == SPREADSHEET
          # Otherwise download from export links as presentation
          download_url = revision['exportLinks'][PRES_LINK] if revision.mimeType == PRESENTATION

          # Download file
          dl            = @client.execute!( :uri => download_url.to_s ) unless download_url.nil?
          modified_date = "#{revision['modifiedDate'].to_s.gsub(/:/,'_')}"
          filename      = "#{file.title}_#{modified_date}_#{revision['lastModifyingUserName']}"
          extension     = "#{download_url[-4,4]}"
          output_file   = "#{new_path}/#{filename}.#{extension}"
          
          # Create downloaded file
          puts "Creating revision: #{file.title} (#{file.id}) ID #{revision.id}"
          IO.binwrite output_file, dl.body

        end
      else
        puts "Cannot download revisions for #{file.title} (#{file.id})"
      end
    end
  end

  def retrieve_revisions(client, file_id)
    drive = client.discovered_api('drive', 'v2')
    api_result = client.execute(
      :api_method => drive.revisions.list,
      :parameters => { 'fileId' => file_id })
    if api_result.status == 200
      revisions = api_result.data
      return revisions.items
    else
      puts "An error occurred: #{result.data['error']['message']}"
    end
  end

end

gd = GoogleDrive.new APPLICATION_NAME, CREDENTIALS_PATH, CLIENT_SECRETS_PATH, SCOPE
gd.download_revisions FOLDER_ID, 'Revisions'
puts "Removing empty directories"
Dir['**/*'].select { |d| File.directory? d }
  .select { |d| (Dir.entries(d) - %w[ . .. ]).empty? }
  .each   { |d| Dir.rmdir d }