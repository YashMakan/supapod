import 'package:serverpod/protocol.dart';
import 'package:serverpod/serverpod.dart';
import 'package:supapod/src/supabase_wrapper.dart';

import 'greeting.dart';
import 'initialize.dart';

class GreetingEndpoint extends Endpoint {
  Future<Greeting> hello(Session session, String name) async {
    final greeting = Greeting(
      message: 'Hello $name',
      author: 'Serverpod',
      timestamp: DateTime.now(),
    );

    // The usual command in serverpod to interact with postgres database
    Greeting.db.insertRow(session, greeting);
    Greeting.db.findFirstRow(session, where: (t) => t.author.equals('John Doe'));

    // supapod command to interact with supabase database
    Supabase.db<Greeting>()?.insertRow(session, greeting);

    // Supapod internally handles the tables and columns as well from the auto-generated code from serverpod
    // so you can expect column names and types to be correct
    Supabase.db<Greeting>()?.findFirstRow(session, where: (t) => (t as GreetingTable).author.equals('John Doe'));

    // with obviously all the goodies that supabase provides like Auth, Realtime, Storage
    Supabase.instance.storage.from('avatars').getPublicUrl('public/avatar1.png');

    return greeting;
  }
}

Future<void> main(List<String> args) async {
  initializeSupabase();

  final pod = Serverpod(
    args,
    Protocol(),
    Endpoints(),
  );

  await pod.start();
}
