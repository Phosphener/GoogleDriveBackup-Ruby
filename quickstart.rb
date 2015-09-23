require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/installed_app'
require 'google/api_client/auth/storage'
require 'google/api_client/auth/storages/file_store'
require 'fileutils'

#Bad security hack to get my SSL to work (or not work as the case may be)
require 'openssl'
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

#Variables needed to authorize and download from the user's google drive
FOLDER_ID = '0B3ten22oqTp1fkY5dllVaTFMczZuRzdSdkZVcXlrMFhkNE1lZXpuT1BYWjJGWXZYN1JRR1k'
APPLICATION_NAME = 'GoogleDriveBackupRuby'
CLIENT_SECRETS_PATH = 'client_secret.json'
CREDENTIALS_PATH = File.join(Dir.home, '.credentials',
                             "drive-quickstart.json")
SCOPE = 'https://www.googleapis.com/auth/drive/auth/drive.metadata.readonly'

#Google drive class that handles authentication of and downloading from a users google drive
class GoogleDrive
  
  def initialize app_name, credentials_path, client_secrets_path, scope
    # Initialize the API
    @client = Google::APIClient.new(:application_name => app_name)
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

    file_store = Google::APIClient::FileStore.new(credentials_path)
    storage = Google::APIClient::Storage.new(file_store)

    auth = storage.authorize

    if auth.nil? || (auth.expired? && auth.refresh_token.nil?)
      app_info = Google::APIClient::ClientSecrets.load(client_secrets_path)
      flow = Google::APIClient::InstalledAppFlow.new({
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
      if file.data.mimeType == 'application/vnd.google-apps.folder'
        new_path = path+'/'+file.data.title
        puts 'Creating folder: '+new_path
        FileUtils::mkdir_p new_path
        download_revisions child.id, new_path
      else
        puts 'Creating file:'+file.data.title
        dl = @client.execute(
          :api_method => @drive_api.files.get,
          :parameters => { 
            :fileId =>  file.data.id,
            :alt => 'media '})
        output_file = path+'/'+file.data.title
        IO.binwrite output_file, dl.body
      end
    end
  end
end

gd = GoogleDrive.new APPLICATION_NAME, CREDENTIALS_PATH, CLIENT_SECRETS_PATH, SCOPE
gd.download_revisions FOLDER_ID, 'Revision'