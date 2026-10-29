defmodule PotokIde.Storage.S3Test do
  # Swaps the storage config, so it cannot run next to other tests.
  use ExUnit.Case, async: false

  alias PotokIde.Storage
  alias PotokIde.Storage.S3

  @key "g1/0b6f2a4e-7c1d-4e7a-9a53-1f1e2d3c4b5a"

  setup do
    previous = Application.get_env(:potok_ide, Storage)

    Application.put_env(:potok_ide, Storage,
      adapter: S3,
      bucket: "examplebucket",
      endpoint: "https://s3.amazonaws.com",
      region: "us-east-1",
      access_key_id: "AKIAIOSFODNN7EXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      virtual_host: true,
      req_options: [plug: {Req.Test, S3}, retry: false]
    )

    on_exit(fn -> Application.put_env(:potok_ide, Storage, previous) end)
  end

  # https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
  # `Req.Utils.aws_sigv4_url/1` is not a public Req API; this pins its output.
  test "presigned URLs match AWS's published example" do
    url =
      S3.presign(:get, "test.txt",
        expires: 86_400,
        datetime: ~U[2013-05-24 00:00:00Z]
      )

    assert url =~ "https://examplebucket.s3.amazonaws.com/test.txt?"

    assert url =~
             "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"

    assert url =~
             "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end

  test "presigned uploads sign the content type and length" do
    assert {:ok, url} = Storage.presign_put(@key, "text/plain", 5)

    assert url =~ "https://examplebucket.s3.amazonaws.com/#{@key}?"
    assert url =~ "X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost"
    assert url =~ "X-Amz-Expires=3600"
  end

  test "downloads redirect to a signed URL that names the file" do
    assert {:redirect, url} =
             Storage.download(@key, "Izveštaj.pdf", "application/pdf", :attachment)

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["response-content-type"] == "application/pdf"

    assert query["response-content-disposition"] ==
             ~s(attachment; filename="Izvestaj.pdf"; filename*=UTF-8''Izve%C5%A1taj.pdf)

    assert query["X-Amz-Expires"] == "7200"
  end

  test "stat reads the stored size with a signed HEAD request" do
    Req.Test.stub(S3, fn conn ->
      assert conn.method == "HEAD"
      assert conn.host == "examplebucket.s3.amazonaws.com"
      assert conn.request_path == "/#{@key}"
      assert ["AWS4-HMAC-SHA256 " <> _] = Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Plug.Conn.put_resp_header("content-length", "5")
      |> Plug.Conn.send_resp(200, "")
    end)

    assert {:ok, 5} = Storage.stat(@key)
  end

  test "stat tells a missing object apart" do
    Req.Test.stub(S3, &Plug.Conn.send_resp(&1, 404, ""))

    assert {:error, :not_found} = Storage.stat(@key)
  end

  test "delete treats a missing object as deleted" do
    Req.Test.stub(S3, fn conn ->
      assert conn.method == "DELETE"
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert :ok = Storage.delete(@key)
  end

  test "keys that were not made by new_key/1 are refused" do
    assert {:error, :invalid_key} = Storage.stat("../etc/passwd")
    assert {:error, :invalid_key} = Storage.delete("g1/not-a-uuid")
  end
end
