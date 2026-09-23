type Empty = Record<never, never>;
type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export type Database = {
  squadquest: {
    Tables: {
      rooms: {
        Row: {
          id: string;
          code: string;
          phase: string;
          identity_step: string;
          state_version: number;
          phase_started_at: string;
          pitch_index: number;
          chaos_released_at: string | null;
          created_by: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          code: string;
          phase?: string;
          identity_step?: string;
          state_version?: number;
          phase_started_at?: string;
          pitch_index?: number;
          chaos_released_at?: string | null;
          created_by?: string;
          created_at?: string;
        };
        Update: {
          id?: string;
          code?: string;
          phase?: string;
          identity_step?: string;
          state_version?: number;
          phase_started_at?: string;
          pitch_index?: number;
          chaos_released_at?: string | null;
          created_by?: string;
          created_at?: string;
        };
        Relationships: [];
      };
      players: {
        Row: {
          id: string;
          room_id: string;
          session_id: string;
          name: string;
          avatar_id: string;
          is_host: boolean;
          last_seen_at: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          room_id: string;
          session_id?: string;
          name: string;
          avatar_id: string;
          is_host?: boolean;
          last_seen_at?: string;
          created_at?: string;
        };
        Update: {
          id?: string;
          room_id?: string;
          session_id?: string;
          name?: string;
          avatar_id?: string;
          is_host?: boolean;
          last_seen_at?: string;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "players_room_id_fkey";
            columns: ["room_id"];
            isOneToOne: false;
            referencedRelation: "rooms";
            referencedColumns: ["id"];
          },
        ];
      };
      identity_submissions: {
        Row: {
          player_id: string;
          room_id: string;
          hidden_story: string;
          dream: string;
          unexpected_story: string;
          submitted_at: string;
        };
        Insert: {
          player_id: string;
          room_id: string;
          hidden_story: string;
          dream: string;
          unexpected_story: string;
          submitted_at?: string;
        };
        Update: Empty;
        Relationships: [];
      };
      identity_rounds: {
        Row: {
          id: string;
          room_id: string;
          round_number: number;
          prompt_key: string;
          answer_text: string;
          author_player_id: string;
          created_at: string;
          revealed_at: string | null;
        };
        Insert: {
          id?: string;
          room_id: string;
          round_number: number;
          prompt_key: string;
          answer_text: string;
          author_player_id: string;
          created_at?: string;
          revealed_at?: string | null;
        };
        Update: Empty;
        Relationships: [];
      };
      identity_votes: {
        Row: {
          id: string;
          round_id: string;
          room_id: string;
          voter_player_id: string;
          guessed_player_id: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          round_id: string;
          room_id: string;
          voter_player_id: string;
          guessed_player_id: string;
          created_at?: string;
        };
        Update: Empty;
        Relationships: [];
      };
    };
    Views: Empty;
    Functions: {
      is_squadquest_room_member: {
        Args: { target_room_id: string };
        Returns: boolean;
      };
      start_squadquest_identity: {
        Args: { target_room_id: string };
        Returns: boolean;
      };
      submit_squadquest_identity_answers: {
        Args: {
          target_room_id: string;
          answer_hidden_story: string;
          answer_dream: string;
          answer_unexpected_story: string;
        };
        Returns: boolean;
      };
      start_squadquest_identity_round: {
        Args: { target_room_id: string };
        Returns: boolean;
      };
      submit_squadquest_identity_vote: {
        Args: { target_room_id: string; guessed_player_id: string };
        Returns: boolean;
      };
      reveal_squadquest_identity_round: {
        Args: { target_room_id: string };
        Returns: boolean;
      };
      get_squadquest_identity_state: {
        Args: { target_room_id: string };
        Returns: Json;
      };
      draw_squadquest_teams: { Args: { target_room_id: string }; Returns: boolean };
      start_squadquest_roles: { Args: { target_room_id: string }; Returns: boolean };
      start_squadquest_mission: { Args: { target_room_id: string }; Returns: boolean };
      add_squadquest_mission_entry: { Args: { target_room_id: string; entry_kind: string; entry_content: string }; Returns: string };
      vote_squadquest_ideas: { Args: { target_room_id: string; idea_ids: string[] }; Returns: boolean };
      vote_squadquest_finalist: { Args: { target_room_id: string; idea_id: string }; Returns: boolean };
      update_squadquest_solution: { Args: { target_room_id: string; solution_data: Json }; Returns: boolean };
      advance_squadquest_mission: { Args: { target_room_id: string; target_team_id: string }; Returns: boolean };
      release_squadquest_chaos: { Args: { target_room_id: string; target_team_id: string | null }; Returns: boolean };
      use_squadquest_role_power: { Args: { target_room_id: string; action_text: string }; Returns: boolean };
      start_squadquest_pitches: { Args: { target_room_id: string }; Returns: boolean };
      advance_squadquest_pitch: { Args: { target_room_id: string }; Returns: boolean };
      submit_squadquest_final_vote: { Args: { target_room_id: string; vote_category: string; target_team_id: string }; Returns: boolean };
      start_squadquest_reveal: { Args: { target_room_id: string }; Returns: boolean };
      start_squadquest_results: { Args: { target_room_id: string }; Returns: boolean };
      start_squadquest_reflection: { Args: { target_room_id: string }; Returns: boolean };
      submit_squadquest_reflection: { Args: { target_room_id: string; target_player_id: string; reflection_text: string }; Returns: boolean };
      finish_squadquest_game: { Args: { target_room_id: string }; Returns: boolean };
      get_squadquest_game_state: { Args: { target_room_id: string }; Returns: Json };
    };
    Enums: {
      game_phase: "waiting" | "identity";
    };
    CompositeTypes: Empty;
  };
};
