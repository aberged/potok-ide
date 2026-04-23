/// <reference types="@capacitor/push-notifications" />

import type { CapacitorConfig } from "@capacitor/cli"

const env = (globalThis as typeof globalThis & {
  process?: {env?: Record<string, string | undefined>}
}).process?.env ?? {}

const argv = (globalThis as typeof globalThis & {
  process?: {argv?: string[]}
}).process?.argv ?? []

const targetPlatform = argv.find((value) => value === "android" || value === "ios")

const defaultServerUrl =
  targetPlatform === "ios" ? "http://localhost:4000" : "http://10.0.2.2:4000"

const platformServerUrl =
  targetPlatform === "ios"
    ? env.CAPACITOR_IOS_SERVER_URL?.trim()
    : targetPlatform === "android"
      ? env.CAPACITOR_ANDROID_SERVER_URL?.trim()
      : undefined

const serverUrl =
  platformServerUrl ||
  env.CAPACITOR_SERVER_URL?.trim() ||
  env.PHX_CAPACITOR_SERVER_URL?.trim() ||
  defaultServerUrl

const cleartext = serverUrl.startsWith("http://")

const config: CapacitorConfig = {
  appId: env.CAPACITOR_APP_ID?.trim() || "com.potok.ide",
  appName: env.CAPACITOR_APP_NAME?.trim() || "Potok",
  webDir: "../priv/capacitor",
  server: {
    url: serverUrl,
    cleartext
  },
  android: {
    allowMixedContent: cleartext
  },
  ios: {
    contentInset: "always"
  },
  plugins: {
    PushNotifications: {
      presentationOptions: ["alert", "sound"]
    },
    SystemBars: {
      insetsHandling: "css"
    }
  }
}

export default config