// External LiveView uploaders. With the S3 storage adapter the server hands
// each entry a presigned PUT URL (PotokIde.Storage.S3), and the browser sends
// the file straight to the bucket, so large files never pass through the app.
//
// The URL is signed with `content-type` and `content-length`: the type must be
// sent exactly as signed, and the browser sets the length from the file.

const S3 = (entries, onViewError) => {
  entries.forEach(entry => {
    const {url, content_type: contentType} = entry.meta
    const xhr = new XMLHttpRequest()

    onViewError(() => xhr.abort())

    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        entry.progress(100)
      } else {
        entry.error()
      }
    }
    xhr.onerror = () => entry.error()

    // 100 is reported by `onload`, once the bucket has accepted the file.
    xhr.upload.addEventListener("progress", event => {
      if (event.lengthComputable) {
        const percent = Math.round((event.loaded / event.total) * 100)

        if (percent < 100) {
          entry.progress(percent)
        }
      }
    })

    xhr.open("PUT", url, true)
    xhr.setRequestHeader("content-type", contentType)
    xhr.send(entry.file)
  })
}

export const Uploaders = {S3}
