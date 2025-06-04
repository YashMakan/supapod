import 'package:supabase/supabase.dart' as sp;
import 'package:serverpod/database.dart';
import 'package:supapod/src/supabase_repository.dart';

class Supabase {
  static late final sp.SupabaseClient instance;

  static final Map<Type, dynamic> _instances = {};

  static void initialize({
    required String supabaseUrl,
    required String supabaseAnonKey,
  }) {
    instance = sp.SupabaseClient(supabaseUrl, supabaseAnonKey);
    print('Supabase client initialized with $supabaseUrl');
  }

  static void register<T extends TableRow<dynamic>>(
      dynamic tableAccessor,
      SupabaseRepository<T> instance,
      ) {
    _instances[T] = instance;
    print('Registered instance of $T');
  }

  static SupabaseRepository<T>? db<T extends TableRow<dynamic>>() {
    return _instances[T] as SupabaseRepository<T>?;
  }
}
