defmodule PotokIde.LinkPreviewsTest do
  use ExUnit.Case, async: true

  alias PotokIde.LinkPreviews
  alias PotokIde.LinkPreviews.HTTP

  @page """
  <!doctype html>
  <html>
    <head>
      <title>Plain title</title>
      <meta property="og:title" content="Example page">
      <meta property="og:description" content="What the page is about.">
      <meta property="og:image" content="/images/card.png">
      <meta property="og:site_name" content="Example">
    </head>
    <body><p>Hello</p></body>
  </html>
  """

  describe "first_url/1" do
    test "finds the first link and leaves out trailing punctuation" do
      assert LinkPreviews.first_url("see https://example.com/a. and https://example.org") ==
               "https://example.com/a"

      assert LinkPreviews.first_url("**https://example.com/b**!") == "https://example.com/b"
      assert LinkPreviews.first_url("(https://example.com/c)") == "https://example.com/c"
    end

    test "keeps brackets that belong to the link" do
      assert LinkPreviews.first_url("[docs](https://example.com/a_(b))") ==
               "https://example.com/a_(b)"
    end

    test "skips links in code" do
      content = """
      ```
      https://code.example.com
      ```
      `https://inline.example.com` then https://example.com/real
      """

      assert LinkPreviews.first_url(content) == "https://example.com/real"
    end

    test "skips links to Potok itself" do
      host = PotokIdeWeb.Endpoint.host()

      assert LinkPreviews.first_url("http://#{host}:4000/groups/1 https://example.com") ==
               "https://example.com"
    end

    test "reads links in HTML content" do
      assert LinkPreviews.first_url(~s(<a href="https://example.com/?a=1&amp;b=2">x</a>)) ==
               "https://example.com/?a=1&b=2"
    end

    test "is nil without a link" do
      assert LinkPreviews.first_url("no links here, www.example.com") == nil
      assert LinkPreviews.first_url("") == nil
      assert LinkPreviews.first_url(nil) == nil
    end
  end

  describe "parse/3" do
    test "reads Open Graph tags and resolves the image against the page" do
      assert {:ok, preview} =
               LinkPreviews.parse(@page, "https://www.example.com/posts/1", "https://ex.am/1")

      assert preview == %{
               "url" => "https://ex.am/1",
               "title" => "Example page",
               "description" => "What the page is about.",
               "site_name" => "Example",
               "image_url" => "https://www.example.com/images/card.png"
             }
    end

    test "falls back to the title tag, the description and the host" do
      html = """
      <html><head>
        <title>  Only a   title </title>
        <meta name="description" content="Plain &amp; simple">
      </head></html>
      """

      assert {:ok, preview} = LinkPreviews.parse(html, "https://www.example.com/")
      assert preview["title"] == "Only a title"
      assert preview["description"] == "Plain & simple"
      assert preview["site_name"] == "example.com"
      assert preview["image_url"] == nil
      assert preview["url"] == "https://www.example.com/"
    end

    test "drops images that are not https" do
      html =
        ~s(<html><head><title>T</title><meta property="og:image" content="http://cdn.example.com/a.png"></head></html>)

      assert {:ok, %{"image_url" => nil}} = LinkPreviews.parse(html, "https://example.com/")
    end

    test "cuts long titles" do
      html = "<html><head><title>#{String.duplicate("a", 500)}</title></head></html>"

      assert {:ok, %{"title" => title}} = LinkPreviews.parse(html, "https://example.com/")
      assert String.length(title) == 200
      assert String.ends_with?(title, "…")
    end

    test "is an error for a page without a title or a description" do
      assert LinkPreviews.parse("<html><body><p>Hi</p></body></html>", "https://example.com/") ==
               :error
    end
  end

  describe "fetch/1" do
    test "fetches the page with Potok's user agent" do
      test_pid = self()

      Req.Test.stub(LinkPreviews, fn conn ->
        send(test_pid, {:requested, conn.host, Plug.Conn.get_req_header(conn, "user-agent")})
        html(conn, @page)
      end)

      assert {:ok, %{"title" => "Example page", "url" => "https://example.com/p"}} =
               LinkPreviews.fetch("https://example.com/p")

      assert_received {:requested, "example.com", [user_agent]}
      assert user_agent =~ "PotokBot"
    end

    test "follows redirects, resolving the image against the final page" do
      Req.Test.stub(LinkPreviews, fn
        %{request_path: "/short"} = conn -> redirect(conn, "/posts/1")
        %{request_path: "/posts/1"} = conn -> html(conn, @page)
      end)

      assert {:ok, preview} = LinkPreviews.fetch("https://example.com/short")
      assert preview["url"] == "https://example.com/short"
      assert preview["image_url"] == "https://example.com/images/card.png"
    end

    test "gives up after three redirects" do
      Req.Test.stub(LinkPreviews, fn conn -> redirect(conn, "/again") end)

      assert LinkPreviews.fetch("https://example.com/loop") == :error
    end

    test "is an error for pages that are not HTML or not found" do
      Req.Test.stub(LinkPreviews, fn
        %{request_path: "/file.pdf"} = conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/pdf")
          |> Plug.Conn.send_resp(200, "%PDF-1.7")

        conn ->
          Plug.Conn.send_resp(conn, 404, "Not found")
      end)

      assert LinkPreviews.fetch("https://example.com/file.pdf") == :error
      assert LinkPreviews.fetch("https://example.com/missing") == :error
    end

    test "reads only the start of a large page" do
      page =
        ~s(<html><head><title>Big page</title>) <>
          "<!--" <>
          String.duplicate("x", 1_100_000) <>
          "-->" <> ~s(<meta name="description" content="Too far"></head></html>)

      Req.Test.stub(LinkPreviews, fn conn -> html(conn, page) end)

      assert {:ok, %{"title" => "Big page", "description" => nil}} =
               LinkPreviews.fetch("https://example.com/big")
    end

    test "never requests private addresses" do
      test_pid = self()

      Req.Test.stub(LinkPreviews, fn conn ->
        send(test_pid, {:requested, conn.host})
        html(conn, @page)
      end)

      for url <- [
            "http://127.0.0.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://[fdaa::3]/",
            "https://db.internal.test/",
            "https://example.com:8080/",
            "ftp://example.com/",
            "https://user:pass@example.com/"
          ] do
        assert LinkPreviews.fetch(url) == :error, url
      end

      refute_received {:requested, _host}
    end

    test "never follows a redirect to a private address" do
      test_pid = self()

      Req.Test.stub(LinkPreviews, fn
        %{host: "example.com", request_path: "/to-metadata"} = conn ->
          redirect(conn, "http://169.254.169.254/")

        %{host: "example.com", request_path: "/to-internal"} = conn ->
          redirect(conn, "https://db.internal.test/admin")

        conn ->
          send(test_pid, {:requested, conn.host})
          html(conn, @page)
      end)

      assert LinkPreviews.fetch("https://example.com/to-metadata") == :error
      assert LinkPreviews.fetch("https://example.com/to-internal") == :error
      refute_received {:requested, _host}
    end
  end

  describe "HTTP.get_image/1" do
    test "takes any file, after a redirect" do
      Req.Test.stub(LinkPreviews, fn
        %{request_path: "/moved"} = conn -> redirect(conn, "/a.png")
        conn -> Plug.Conn.send_resp(conn, 200, "picture")
      end)

      assert HTTP.get_image("https://example.com/moved") == {:ok, "picture"}
    end

    test "refuses a file over the limit rather than cut it" do
      Req.Test.stub(LinkPreviews, fn conn ->
        Plug.Conn.send_resp(conn, 200, :binary.copy("x", 5_000_001))
      end)

      assert HTTP.get_image("https://example.com/huge.png") == :error
    end

    test "refuses what is not there" do
      Req.Test.stub(LinkPreviews, fn conn -> Plug.Conn.send_resp(conn, 404, "picture") end)

      assert HTTP.get_image("https://example.com/gone.png") == :error
    end

    test "never asks a private address" do
      test_pid = self()

      Req.Test.stub(LinkPreviews, fn
        %{host: "example.com"} = conn ->
          redirect(conn, "http://169.254.169.254/")

        conn ->
          send(test_pid, {:requested, conn.host})
          Plug.Conn.send_resp(conn, 200, "picture")
      end)

      assert HTTP.get_image("https://db.internal.test/a.png") == :error
      assert HTTP.get_image("https://example.com/a.png") == :error
      refute_received {:requested, _host}
    end
  end

  describe "HTTP.public_address?/1" do
    test "refuses private, local and reserved addresses" do
      for address <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {172, 31, 255, 255},
            {192, 168, 1, 1},
            {169, 254, 169, 254},
            {100, 64, 0, 1},
            {0, 0, 0, 0},
            {224, 0, 0, 1},
            {255, 255, 255, 255},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001},
            {0xFDAA, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1}
          ] do
        refute HTTP.public_address?(address), inspect(address)
      end
    end

    test "allows public addresses" do
      for address <- [
            {93, 184, 215, 14},
            {172, 32, 0, 1},
            {203, 0, 113, 10},
            {0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD70E},
            {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}
          ] do
        assert HTTP.public_address?(address), inspect(address)
      end
    end
  end

  defp html(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, body)
  end

  defp redirect(conn, location) do
    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(302, "")
  end
end
