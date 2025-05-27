import 'greeting.dart';
import 'package:supapod/supapod.dart';
import 'package:supapod/supapod.dart' show Supabase, SupabaseRepository;

void initializeSupabase() {
  Supabase.initialize(
    supabaseUrl: 'SUPABASE_URL',
    supabaseAnonKey: 'SUPABASE_ANON_KEY',
  );

  var greetingInstance = GreetingSupabaseRepository(Greeting.t);
  Supabase.register<Greeting>(Greeting.t, greetingInstance);

  // --- Initialize all your auto-generated Models here like above ---
}

// --- Initialize all your auto-generated Models here like above ---

class GreetingSupabaseRepository extends SupabaseRepository<Greeting> {
  GreetingSupabaseRepository(super._table);
}