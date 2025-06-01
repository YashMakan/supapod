import 'package:serverpod/serverpod.dart' as _i1;
import 'package:supabase/supabase.dart';
import 'package:supapod/src/supabase_helper.dart';
import 'package:supapod/src/supabase_wrapper.dart';

class SupabaseRepository<T extends _i1.TableRow<dynamic>> {
  final _i1.Table _table;

  _i1.Table get t => _table;

  SupabaseClient get supabase => Supabase.instance;

  const SupabaseRepository(this._table);

  /// Returns a list of [T]s matching the given query parameters.
  ///
  /// Use [where] to specify which items to include in the return value.
  /// If none is specified, all items will be returned.
  ///
  /// To specify the order of the items use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// The maximum number of items can be set by [limit]. If no limit is set,
  /// all items matching the query will be returned.
  ///
  /// [offset] defines how many items to skip, after which [limit] (or all)
  /// items are read from the database.
  ///
  /// ```dart
  /// var persons = await Persons.db.find(
  ///   session,
  ///   where: (t) => t.lastName.equals('Jones'),
  ///   orderBy: (t) => t.firstName,
  ///   limit: 100,
  /// );
  /// ```
  Future<List<T>> find(
    _i1.Session session, {
    _i1.WhereExpressionBuilder<_i1.Table>? where,
    int? limit,
    int? offset,
    _i1.OrderByBuilder<_i1.Table>? orderBy,
    bool orderDescending = false,
    _i1.OrderByListBuilder<_i1.Table>? orderByList,
    _i1.Transaction? transaction,
  }) async {
    final tableName = _table.tableName;
    PostgrestFilterBuilder builder = supabase.from(tableName).select();

    // serverpod -> t.name.equals('Serverpod')
    // supabase  -> supabase.from(tableName).select().eq('name', 'Serverpod')
    session.log("****tableName: $tableName -> where::$where & ${where == null}");
    // Apply `where` if available
    if (where != null) {
      session.log("****expr.columns IN");
      final expr = where(_table);
      session.log("****expr.columns: ${expr.columns}");
      builder = SupabaseHelper().applyExpression(builder, expr, _table);
    }

    PostgrestTransformBuilder transformBuilder = builder;

    // Apply ordering
    if (orderBy != null) {
      final column = orderBy(_table);
      transformBuilder = transformBuilder.order(column.columnName, ascending: !orderDescending);
    }

    // Apply multiple orderBy (if provided)
    if (orderByList != null) {
      final orders = orderByList(_table);
      for (final order in orders) {
        transformBuilder = transformBuilder.order(
          order.column.columnName,
          ascending: !order.orderDescending,
        );
      }
    }

    // Pagination
    if (limit != null) {
      transformBuilder = transformBuilder.limit(limit);
    }

    if (offset != null) {
      transformBuilder = transformBuilder.range(offset, offset + (limit ?? 100) - 1);
    }

    final response = await transformBuilder;

    // Deserialize into List<T>
    final List<T> results = [];
    for (final row in response) {
      results.add(session.serverpod.serializationManager.deserialize<T>(row));
    }
    return results;
  }

  /// Returns the first matching [T] matching the given query parameters.
  ///
  /// Use [where] to specify which items to include in the return value.
  /// If none is specified, all items will be returned.
  ///
  /// To specify the order use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// [offset] defines how many items to skip, after which the next one will be picked.
  ///
  /// ```dart
  /// var youngestPerson = await Persons.db.findFirstRow(
  ///   session,
  ///   where: (t) => t.lastName.equals('Jones'),
  ///   orderBy: (t) => t.age,
  /// );
  /// ```
  Future<T?> findFirstRow(
    _i1.Session session, {
    _i1.WhereExpressionBuilder<_i1.Table>? where,
    int? offset,
    _i1.OrderByBuilder<_i1.Table>? orderBy,
    bool orderDescending = false,
    _i1.OrderByListBuilder<_i1.Table>? orderByList,
    _i1.Transaction? transaction,
  }) async {
    final tableName = _table.tableName;
    PostgrestTransformBuilder builder = supabase.from(tableName).select();

    // add where
    if (where != null) {
      final expr = where(_table);
      print("expr.columns: ${expr.columns}");
      // todo: implement where clause for multiple expressions
    }
    // orderBy
    if (orderBy != null) {
      final column = orderBy(_table);
      builder = builder.order(column.columnName, ascending: !orderDescending);
    }
    // orderByList
    if (orderByList != null) {
      final orders = orderByList(_table);
      for (final order in orders) {
        builder = builder.order(
          order.column.columnName,
          ascending: !order.orderDescending,
        );
      }
    }

    // offset
    if (offset != null) {
      builder = builder.range(offset, offset + 1);
    }

    final response = await builder;
    if (response.isEmpty) {
      return null;
    }
    return session.serverpod.serializationManager.deserialize<T>(response[0]);
  }

  /// Finds a single [T] by its [id] or null if no such row exists.
  Future<T?> findById(
    _i1.Session session,
    int id, {
    _i1.Transaction? transaction,
  }) async {
    return findFirstRow(
      session,
      where: (t) => t.id.equals(id),
      transaction: transaction,
    );
  }

  /// Inserts all [T]s in the list and returns the inserted rows.
  ///
  /// The returned [T]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// insert, none of the rows will be inserted.
  Future<List<T>> insert(
    _i1.Session session,
    List<T> rows, {
    _i1.Transaction? transaction,
  }) async {
    final tableName = _table.tableName;
    final resultData = await supabase
        .from(tableName)
        .insert(rows.map((e) => e.toJson()).toList())
        .select();
    List<T> results = [];
    for (int i = 0; i < resultData.length; i++) {
      var dbRowMap = resultData[i];
      var originalRowMap = rows[i].toJson();
      var mergedMap = {...originalRowMap, ...dbRowMap};
      results.add(
        session.serverpod.serializationManager.deserialize<T>(mergedMap),
      );
    }
    return results;
  }

  /// Inserts a single [T] and returns the inserted row.
  ///
  /// The returned [T] will have its `id` field set.
  Future<T> insertRow(
    _i1.Session session,
    T row, {
    _i1.Transaction? transaction,
  }) async {
    final tableName = _table.tableName;
    final resultData = await supabase
        .from(tableName)
        .insert(row.toJson())
        .select();
    var dbRowMap = resultData[0];
    var originalRowMap = row.toJson();
    var mergedMap = {...originalRowMap, ...dbRowMap};
    return session.serverpod.serializationManager.deserialize<T>(Map<String, dynamic>.from(mergedMap));
  }

  /// Updates all [T]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  Future<List<T>> update(
    _i1.Session session,
    List<T> rows, {
    _i1.ColumnSelections<_i1.Table>? columns,
    _i1.Transaction? transaction,
  }) async {
    final tableName = _table.tableName;
    final resultData = await supabase
        .from(tableName)
        .upsert((rows.map((e) => e.toJson()).toList()))
        .select();

    List<T> results = [];
    for (int i = 0; i < resultData.length; i++) {
      var dbRowMap = resultData[i];
      var originalRowMap = rows[i].toJson();
      var mergedMap = {...originalRowMap, ...dbRowMap};
      results.add(
        session.serverpod.serializationManager.deserialize<T>(mergedMap),
      );
    }
    return results;
  }

  /// Updates a single [T]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<T> updateRow(
    _i1.Session session,
    T row, {
    _i1.ColumnSelections<_i1.Table>? columns,
    _i1.Transaction? transaction,
  }) async {
    final tableName = _table.tableName;
    final resultData = await supabase
        .from(tableName)
        .upsert(row.toJson())
        .select();
    var dbRowMap = resultData[0];
    var originalRowMap = row.toJson();
    var mergedMap = {...originalRowMap, ...dbRowMap};
    return session.serverpod.serializationManager.deserialize<T>(mergedMap);
  }

  /// Deletes all [T]s in the list and returns the deleted rows.
  /// This is an atomic operation, meaning that if one of the rows fail to
  /// be deleted, none of the rows will be deleted.
  Future<List<T>> delete(
    _i1.Session session,
    List<T> rows, {
    _i1.Transaction? transaction,
  }) async {
    final tableName = _table.tableName;
    final resultData = await supabase
        .from(tableName)
        .delete()
        .inFilter(_table.id.columnName, rows.map((e) => e.id).toList())
        .select();
    List<T> results = [];

    for (int i = 0; i < resultData.length; i++) {
      var dbRowMap = resultData[i];
      var originalRowMap = rows[i].toJson();
      var mergedMap = {...originalRowMap, ...dbRowMap};
      results.add(
        session.serverpod.serializationManager.deserialize<T>(mergedMap),
      );
    }
    return results;
  }

  /// Deletes a single [T].
  Future<T> deleteRow(
    _i1.Session session,
    T row, {
    _i1.Transaction? transaction,
  }) async {
    final tableName = _table.tableName;
    final resultData = await supabase
        .from(tableName)
        .delete()
        .eq(_table.id.columnName, row.id)
        .select();

    var dbRowMap = resultData[0];
    var originalRowMap = row.toJson();
    var mergedMap = {...originalRowMap, ...dbRowMap};
    return session.serverpod.serializationManager.deserialize<T>(mergedMap);
  }

  /// Deletes all rows matching the [where] expression.
  Future<List<T>> deleteWhere(
    _i1.Session session, {
    required _i1.WhereExpressionBuilder<_i1.Table> where,
    _i1.Transaction? transaction,
  }) async {
    return session.db.deleteWhere<T>(
      where: where(_table),
      transaction: transaction,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _i1.Session session, {
    _i1.WhereExpressionBuilder<_i1.Table>? where,
    int? limit,
    _i1.Transaction? transaction,
  }) async {
    final tableName = _table.tableName;
    PostgrestFilterBuilder builder = supabase.from(tableName).select();
    // Apply `where` if available
    if (where != null) {
      final expr = where(_table);
      print("expr.columns: ${expr.columns}");
      builder = SupabaseHelper().applyExpression(builder, expr, _table);
    }
    // Apply pagination
    if (limit != null) {
      throw UnsupportedError("count() does not support pagination");
    }
    final response = await builder;
    return response.length;
  }
}
