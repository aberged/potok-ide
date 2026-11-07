// GIFs, stickers and pictures sent from the keyboard in the Android app
// (KeyboardContentPlugin.java). A keyboard offers them only to a field that
// takes them, which a page cannot say by itself, so the app says it while this
// hook is on the page. What comes goes out at once, as a message of its own,
// through the `keyboard_media` upload: what is typed stays in the composer.

import {Capacitor, registerPlugin} from "@capacitor/core"
import {base64ToBytes} from "./share_inbox"

const NativeKeyboardContent = registerPlugin("KeyboardContent")

const CHUNK_SIZE = 1024 * 1024

// Builds without the plugin keep working; their keyboards just offer no GIFs.
const nativeKeyboard = () =>
  Capacitor.isNativePlatform() && Capacitor.isPluginAvailable("KeyboardContent")

const readFile = async item => {
  const parts = []

  for (let offset = 0; offset < item.size; offset += CHUNK_SIZE) {
    const {data} = await NativeKeyboardContent.readChunk({
      id: item.id,
      offset,
      length: CHUNK_SIZE,
    })

    parts.push(base64ToBytes(data))
  }

  return new File(parts, item.name, {type: item.mimeType})
}

export const KeyboardMedia = {
  mounted() {
    if (!nativeKeyboard()) {
      return
    }

    this.listener = NativeKeyboardContent.addListener("contentReceived", item => {
      void this.receive(item)
    })

    void NativeKeyboardContent.start()
  },

  destroyed() {
    if (!this.listener) {
      return
    }

    void Promise.resolve(this.listener).then(listener => listener.remove())
    void NativeKeyboardContent.stop()
  },

  async receive(item) {
    if (item.failed) {
      this.pushEvent("keyboard_media_failed", {})
      return
    }

    try {
      // Every field on the page takes keyboard content, but only the composer's
      // goes out: a GIF picked while searching must not land in the chat.
      const composer = document.getElementById("group-value-content")

      if (this.el.dataset.canSend === "true" && composer && document.activeElement === composer) {
        this.upload("keyboard_media", [await readFile(item)])
      } else {
        this.pushEvent("keyboard_media_refused", {})
      }
    } catch (_error) {
      this.pushEvent("keyboard_media_failed", {})
    } finally {
      await NativeKeyboardContent.clear({id: item.id}).catch(() => {})
    }
  },
}
