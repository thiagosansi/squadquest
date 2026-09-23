import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";

export type SquadQuestSupabaseClient = SupabaseClient<Database, "squadquest">;

let browserClient: SquadQuestSupabaseClient | null = null;

export function hasSupabaseConfig(): boolean {
  return Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && getSupabaseApiKey());
}

function getSupabaseApiKey(): string | undefined {
  return process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
}

export function getSupabaseBrowserClient(): SquadQuestSupabaseClient | null {
  if (!hasSupabaseConfig()) return null;
  if (!browserClient) {
    const apiKey = getSupabaseApiKey();
    if (!apiKey) return null;
    browserClient = createClient<Database, "squadquest">(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      apiKey,
      {
        db: { schema: "squadquest" },
        auth: {
          persistSession: true,
          autoRefreshToken: true,
          detectSessionInUrl: false,
          // One browser tab represents one anonymous player during local testing.
          // A real player on another device still receives an independent session.
          storage: typeof window === "undefined" ? undefined : window.sessionStorage,
        },
      },
    );
  }
  return browserClient;
}
