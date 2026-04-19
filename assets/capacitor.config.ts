import type { CapacitorConfig } from "@capacitor/cli"

const env = (globalThis as typeof globalThis & {
  process?: {env?: Record<string, string | undefined>}
}).process?.env ?? {}

const serverUrl =
  env.CAPACITOR_SERVER_URL?.trim() ||
  env.PHX_CAPACITOR_SERVER_URL?.trim() ||
  "http://10.0.2.2:4000"

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
  plugins: {
    SystemBars: {
      insetsHandling: "css"
    }
  }
}

export default config