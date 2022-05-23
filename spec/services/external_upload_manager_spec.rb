# frozen_string_literal: true

RSpec.describe ExternalUploadManager do
  fab!(:user) { Fabricate(:user) }
  let(:type) { "card_background" }
  let!(:logo_file) { file_from_fixtures("logo.png") }
  let!(:pdf_file) { file_from_fixtures("large.pdf", "pdf") }
  let(:object_size) { 1.megabyte }
  let(:etag) { "e696d20564859cbdf77b0f51cbae999a" }
  let(:client_sha1) { Upload.generate_digest(object_file) }
  let(:sha1) { Upload.generate_digest(object_file) }
  let(:object_file) { logo_file }
  let(:metadata_headers) { {} }
  let!(:external_upload_stub) { Fabricate(:image_external_upload_stub, created_by: user) }
  let(:upload_base_url) { "https://#{SiteSetting.s3_upload_bucket}.s3.#{SiteSetting.s3_region}.amazonaws.com" }
  let(:s3_bucket_name) { SiteSetting.s3_upload_bucket }

  subject do
    ExternalUploadManager.new(external_upload_stub)
  end

  before do
    SiteSetting.authorized_extensions += "|pdf"
    SiteSetting.max_attachment_size_kb = 210.megabytes / 1000

    setup_s3

    SiteSetting.s3_backup_bucket = "s3-backup-bucket"
    SiteSetting.backup_location = BackupLocationSiteSetting::S3

    stub_copy_and_delete
    # stub_head_object
    stub_download_object_filehelper
    # stub_copy_object
    # stub_delete_object
  end

  describe "#ban_user_from_external_uploads!" do
    after { Discourse.redis.flushdb }

    it "bans the user from external uploads using a redis key" do
      ExternalUploadManager.ban_user_from_external_uploads!(user: user)
      expect(ExternalUploadManager.user_banned?(user)).to eq(true)
    end
  end

  describe "#can_promote?" do
    it "returns false if the external stub status is not created" do
      external_upload_stub.update!(status: ExternalUploadStub.statuses[:uploaded])
      expect(subject.can_promote?).to eq(false)
    end
  end

  describe "#transform!" do
    context "when stubbed upload is < DOWNLOAD_LIMIT (small enough to download + generate sha)" do
      let!(:external_upload_stub) { Fabricate(:image_external_upload_stub, created_by: user, filesize: object_size) }
      let(:object_size) { 1.megabyte }
      let(:object_file) { logo_file }

      context "when the download of the s3 file fails" do
        before do
          FileHelper.stubs(:download).returns(nil)
        end

        it "raises an error" do
          expect { subject.transform! }.to raise_error(ExternalUploadManager::DownloadFailedError)
        end
      end

      context "when the upload is not in the created status" do
        before do
          external_upload_stub.update!(status: ExternalUploadStub.statuses[:uploaded])
        end
        it "raises an error" do
          expect { subject.transform! }.to raise_error(ExternalUploadManager::CannotPromoteError)
        end
      end

      context "when the upload does not get changed in UploadCreator (resized etc.)" do
        it "copies the stubbed upload on S3 to its new destination and deletes it" do
          upload = subject.transform!
          expect(WebMock).to have_requested(
            :put,
            "#{upload_base_url}/#{Discourse.store.get_path_for_upload(upload)}",
          ).with(headers: { 'X-Amz-Copy-Source' => "#{SiteSetting.s3_upload_bucket}/#{external_upload_stub.key}" })
          expect(WebMock).to have_requested(
            :delete,
            "#{upload_base_url}/#{external_upload_stub.key}"
          )
        end

        it "errors if the image upload is too big" do
          SiteSetting.max_image_size_kb = 1
          upload = subject.transform!
          expect(upload.errors.full_messages).to include(
            "Filesize " + I18n.t("upload.images.too_large_humanized", max_size: ActiveSupport::NumberHelper.number_to_human_size(SiteSetting.max_image_size_kb.kilobytes))
          )
        end

        it "errors if the extension is not supported" do
          SiteSetting.authorized_extensions = ""
          upload = subject.transform!
          expect(upload.errors.full_messages).to include(
            "Original filename " + I18n.t("upload.unauthorized", authorized_extensions: "")
          )
        end
      end

      context "when the upload does get changed by the UploadCreator" do
        let(:file) { file_from_fixtures("should_be_jpeg.heic", "images") }

        it "creates a new upload in s3 (not copy) and deletes the original stubbed upload" do
          upload = subject.transform!
          # expect(WebMock).to have_requested(
          #   :put,
          #   "#{upload_base_url}/#{Discourse.store.get_path_for_upload(upload)}",
          # )
          # expect(WebMock).to have_requested(
          #   :delete, "#{upload_base_url}/#{external_upload_stub.key}"
          # )
        end
      end

      context "when the sha has been set on the s3 object metadata by the clientside JS" do
        let(:metadata_headers) { { "x-amz-meta-sha1-checksum" => client_sha1 } }

        context "when the downloaded file sha1 does not match the client sha1" do
          let(:client_sha1) { "blahblah" }

          it "raises an error, deletes the stub" do
            expect { subject.transform! }.to raise_error(ExternalUploadManager::ChecksumMismatchError)
            expect(ExternalUploadStub.exists?(id: external_upload_stub.id)).to eq(false)
          end

          it "does not delete the stub if enable_upload_debug_mode" do
            SiteSetting.enable_upload_debug_mode = true
            expect { subject.transform! }.to raise_error(ExternalUploadManager::ChecksumMismatchError)
            external_stub = ExternalUploadStub.find(external_upload_stub.id)
            expect(external_stub.status).to eq(ExternalUploadStub.statuses[:failed])
          end
        end
      end

      context "when the downloaded file size does not match the expected file size for the upload stub" do
        before do
          external_upload_stub.update!(filesize: 10)
        end

        after { Discourse.redis.flushdb }

        it "raises an error, deletes the file immediately, and prevents the user from uploading external files for a few minutes" do
          expect { subject.transform! }.to raise_error(ExternalUploadManager::SizeMismatchError)
          expect(ExternalUploadStub.exists?(id: external_upload_stub.id)).to eq(false)
          expect(Discourse.redis.get("#{ExternalUploadManager::BAN_USER_REDIS_PREFIX}#{external_upload_stub.created_by_id}")).to eq("1")
          expect(WebMock).to have_requested(
            :delete,
            "#{upload_base_url}/#{external_upload_stub.key}"
          )
        end

        it "does not delete the stub if enable_upload_debug_mode" do
          SiteSetting.enable_upload_debug_mode = true
          expect { subject.transform! }.to raise_error(ExternalUploadManager::SizeMismatchError)
          external_stub = ExternalUploadStub.find(external_upload_stub.id)
          expect(external_stub.status).to eq(ExternalUploadStub.statuses[:failed])
        end
      end
    end

    context "when stubbed upload is > DOWNLOAD_LIMIT (too big to download, generate a fake sha)" do
      let(:object_size) { 200.megabytes }
      let(:object_file) { pdf_file }
      let!(:external_upload_stub) { Fabricate(:attachment_external_upload_stub, created_by: user, filesize: object_size) }

      before do
        UploadCreator.any_instance.stubs(:generate_fake_sha1_hash).returns("testbc60eb18e8f974cbfae8bb0f069c3a311024")
      end

      it "does not try and download the file" do
        FileHelper.expects(:download).never
        subject.transform!
      end

      it "generates a fake sha for the upload record" do
        upload = subject.transform!
        expect(upload.sha1).not_to eq(sha1)
        expect(upload.original_sha1).to eq(nil)
        expect(upload.filesize).to eq(object_size)
      end

      it "marks the stub as uploaded" do
        subject.transform!
        expect(external_upload_stub.reload.status).to eq(ExternalUploadStub.statuses[:uploaded])
      end

      it "copies the stubbed upload on S3 to its new destination and deletes it" do
        upload = subject.transform!

        bucket = @fake_s3.bucket(SiteSetting.s3_upload_bucket)
        expect(bucket.find_object(Discourse.store.get_path_for_upload(upload))).to be_present
        expect(bucket.find_object(external_upload_stub.key)).to be_nil
      end
    end

    context "when the upload type is backup" do
      let(:upload_base_url) { "https://#{SiteSetting.s3_backup_bucket}.s3.#{SiteSetting.s3_region}.amazonaws.com" }
      let(:object_size) { 200.megabytes }
      let(:object_file) { file_from_fixtures("backup_since_v1.6.tar.gz", "backups") }
      let!(:external_upload_stub) do
        Fabricate(
          :attachment_external_upload_stub,
          created_by: user,
          filesize: object_size,
          upload_type: "backup",
          original_filename: "backup_since_v1.6.tar.gz",
          folder_prefix: RailsMultisite::ConnectionManagement.current_db
        )
      end
      let(:s3_bucket_name) { SiteSetting.s3_backup_bucket }

      before do
        # stub_request(:head, "https://#{SiteSetting.s3_backup_bucket}.s3.#{SiteSetting.s3_region}.amazonaws.com/")
        #
        # # stub copy and delete object for backup, which copies the original filename to the root,
        # # and also uses current_db in the bucket name always
        # stub_request(
        #   :put,
        #   "#{upload_base_url}/#{RailsMultisite::ConnectionManagement.current_db}/backup_since_v1.6.tar.gz"
        # ).to_return(
        #   status: 200,
        #   headers: { "ETag" => etag },
        #   body: copy_object_result
        # )
      end

      it "does not try and download the file" do
        FileHelper.expects(:download).never
        subject.transform!
      end

      it "raises an error when backups are disabled" do
        SiteSetting.enable_backups = false
        expect { subject.transform! }.to raise_error(Discourse::InvalidAccess)
      end

      it "raises an error when backups are local, not s3" do
        SiteSetting.backup_location = BackupLocationSiteSetting::LOCAL
        expect { subject.transform! }.to raise_error(Discourse::InvalidAccess)
      end

      it "does not create an upload record" do
        expect { subject.transform! }.not_to change { Upload.count }
      end

      it "copies the stubbed upload on S3 to its new destination and deletes it" do
        bucket = @fake_s3.bucket(SiteSetting.s3_backup_bucket)
        expect(bucket.find_object(external_upload_stub.key)).to be_present

        subject.transform!

        expect(bucket.find_object("#{RailsMultisite::ConnectionManagement.current_db}/backup_since_v1.6.tar.gz")).to be_present
        expect(bucket.find_object(external_upload_stub.key)).to be_nil
      end
    end
  end

  # def stub_head_object
  #   stub_request(
  #     :head,
  #     "#{upload_base_url}/#{external_upload_stub.key}"
  #   ).to_return(
  #     status: 200,
  #     headers: {
  #       ETag: etag,
  #       "Content-Length" => object_size,
  #       "Content-Type" => "image/png",
  #     }.merge(metadata_headers)
  #   )
  # end

  def stub_download_object_filehelper
    signed_url = Discourse.store.signed_url_for_path(external_upload_stub.key)
    uri = URI.parse(signed_url)
    signed_url = uri.to_s.gsub(uri.query, "")
    stub_request(:get, signed_url).with(query: hash_including({})).to_return(
      status: 200,
      body: object_file.read
    )
  end

  # def copy_object_result
  #   <<~XML
  #   <?xml version=\"1.0\" encoding=\"UTF-8\"?>\n
  #   <CopyObjectResult
  #     xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">
  #     <LastModified>2021-07-19T04:10:41.000Z</LastModified>
  #     <ETag>&quot;#{etag}&quot;</ETag>
  #   </CopyObjectResult>
  #   XML
  # end
  #
  # def stub_copy_object
  #   upload_pdf = Fabricate(:upload, sha1: "testbc60eb18e8f974cbfae8bb0f069c3a311024", original_filename: "test.pdf", extension: "pdf")
  #   upload_path = Discourse.store.get_path_for_upload(upload_pdf)
  #   upload_pdf.destroy!
  #
  #   stub_request(
  #     :put,
  #     "#{upload_base_url}/#{upload_path}"
  #   ).to_return(
  #     status: 200,
  #     headers: { "ETag" => etag },
  #     body: copy_object_result
  #   )
  #
  #   upload_png = Fabricate(:upload, sha1: "bc975735dfc6409c1c2aa5ebf2239949bcbdbd65", original_filename: "test.png", extension: "png")
  #   upload_path = Discourse.store.get_path_for_upload(upload_png)
  #   upload_png.destroy!
  #   stub_request(
  #     :put,
  #     "#{upload_base_url}/#{upload_path}"
  #   ).to_return(
  #     status: 200,
  #     headers: { "ETag" => etag },
  #     body: copy_object_result
  #   )
  # end
  #
  # def stub_delete_object
  #   stub_request(
  #     :delete, "#{upload_base_url}/#{external_upload_stub.key}"
  #   ).to_return(
  #     status: 200
  #   )
  # end

  # class FakeS3
  #   attr_reader :s3_client
  #
  #   def initialize(s3_bucket_name = SiteSetting.s3_upload_bucket)
  #     @objects = {}
  #
  #     @s3_client = Aws::S3::Client.new(stub_responses: true, region: SiteSetting.s3_region)
  #     @s3_helper = S3Helper.new(
  #       s3_bucket_name,
  #       Rails.configuration.multisite ? FileStore::S3Store::multisite_tombstone_prefix : FileStore::S3Store::TOMBSTONE_PREFIX,
  #       client: @s3_client
  #     )
  #
  #     stub_s3
  #   end
  #
  #   def put_object(obj)
  #     @objects[obj[:key]] = obj
  #   end
  #
  #   def delete_object(key)
  #     @objects.delete(key)
  #   end
  #
  #   def find_object(key)
  #     @objects[key]
  #   end
  #
  #   private
  #
  #   def stub_s3
  #     S3Helper.stubs(:new).returns(@s3_helper)
  #
  #     @s3_client.stub_responses(:head_object, -> (context) do
  #       if object = find_object(context.params[:key])
  #         { content_length: object[:size], last_modified: object[:last_modified] }
  #       else
  #         { status_code: 404, headers: {}, body: "", }
  #       end
  #     end)
  #
  #     @s3_client.stub_responses(:get_object, -> (context) do
  #       if object = find_object(context.params[:key])
  #         { content_length: object[:size], body: "" }
  #       else
  #         { status_code: 404, headers: {}, body: "", }
  #       end
  #     end)
  #
  #     @s3_client.stub_responses(:delete_object, -> (context) do
  #       delete_object(context.params[:key])
  #       nil
  #     end)
  #
  #     @s3_client.stub_responses(:copy_object, -> (context) do
  #       copy_source_key = context.params[:copy_source].delete_prefix("#{@s3_helper.s3_bucket_name}/")
  #
  #       if context.params[:metadata_directive] == "REPLACE"
  #         attribute_overrides = context.params.except(:copy_source, :bucket, :metadata_directive)
  #       else
  #         attribute_overrides = context.params.slice(:key)
  #       end
  #
  #       new_object = find_object(copy_source_key).dup.merge(attribute_overrides)
  #       put_object(new_object)
  #       { copy_object_result: { etag: "e696d20564859cbdf77b0f51cbae999a" } }
  #     end)
  #
  #     @s3_client.stub_responses(:create_multipart_upload, -> (context) do
  #       puts context.params
  #     end)
  #
  #     @s3_client.stub_responses(:put_object, -> (context) do
  #       put_object(context.params)
  #       nil
  #     end)
  #   end
  # end

  def stub_copy_and_delete
    @fake_s3 = FakeS3.create

    @fake_s3.bucket(s3_bucket_name).put_object(
      key: external_upload_stub.key,
      size: object_size,
      last_modified: Time.zone.now
    )

    # upload_png = Fabricate(:upload, sha1: "bc975735dfc6409c1c2aa5ebf2239949bcbdbd65", original_filename: "test.png", extension: "png")
    # upload_pdf = Fabricate(:upload, sha1: "testbc60eb18e8f974cbfae8bb0f069c3a311024", original_filename: "test.pdf", extension: "pdf")
    #
    #
    # @objects = [
    #   {
    #     key: Discourse.store.get_path_for_upload(upload_png),
    #     size: upload_png.filesize,
    #     last_modified: Time.zone.now
    #   },
    #   {
    #     key: Discourse.store.get_path_for_upload(upload_pdf),
    #     size: upload_pdf.filesize,
    #     last_modified: Time.zone.now
    #   },
    #   {
    #     key: external_upload_stub.key,
    #     size: object_size,
    #     last_modified: Time.zone.now,
    #     metadata: {
    #       "sha1-checksum" => "b"
    #     }
    #   }
    # ]
    #
    # upload_png.destroy!
    # upload_pdf.destroy!
  end
end
