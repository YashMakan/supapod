import 'package:serverpod/serverpod.dart';
import 'package:supabase/supabase.dart';

class SupabaseHelper {

  // --- Helper to parse the RHS string from a ColumnExpression's toString() output ---
  String _extractRhsString(ColumnExpression expr) {
    final String fullExpressionString = expr.toString();
    final String columnString = expr.column.toString();
    final String operatorString = expr.operator;

    // Expected format: "{columnString} {operatorString} {rhsValueString}"
    // Or for IS NULL/NOT NULL: "{columnString} {operatorString}"

    if (!fullExpressionString.startsWith(columnString)) {
      // Attempt a more flexible parsing if the start doesn't match exactly
      // (e.g. due to subtle quoting differences not captured by column.toString())
      final opIndex = fullExpressionString.indexOf(' $operatorString ');
      if (opIndex != -1) {
        return fullExpressionString.substring(opIndex + operatorString.length + 2).trim();
      }
      throw FormatException(
          "ColumnExpression string '${fullExpressionString}' did not start with expected column string '${columnString}'.");
    }

    int rhsStartIndex = columnString.length + 1 + operatorString.length;
    if (operatorString == 'IS NULL' || operatorString == 'IS NOT NULL') {
      // These operators do not have a following RHS value string.
      return "";
    }

    // Ensure there's a space after the operator if there's an RHS
    if (fullExpressionString.length > rhsStartIndex && fullExpressionString[rhsStartIndex] == ' ') {
      rhsStartIndex++;
    } else if (fullExpressionString.length > columnString.length + operatorString.length && fullExpressionString[columnString.length + operatorString.length] == ' ') {
      // This case handles if operatorString itself has spaces and we miscalculated rhsStartIndex initially
      // e.g. columnString + ' ' + "IS DISTINCT FROM" + ' ' + rhs
      // Do nothing, rhsStartIndex should be okay after the full operator.
    }
    else if (rhsStartIndex < fullExpressionString.length) {
      // No space after operator, but there is more string. This is unusual for value expressions.
      // Or it means operator was multi-word and we only took the first word for operatorString.
      // This parsing needs to be robust to how expr.operator is defined vs. how it appears in toString().
      // A safer bet is to find the operator with surrounding spaces.
      final opWithSpaces = ' $operatorString ';
      final opLocation = fullExpressionString.indexOf(opWithSpaces, columnString.length);
      if (opLocation != -1) {
        rhsStartIndex = opLocation + opWithSpaces.length;
      } else {
        // Operator might be at the very end (e.g. custom unary op if that existed)
        // or toString() is not what we expect.
      }
    }


    if (rhsStartIndex >= fullExpressionString.length) {
      // This can happen if the operator is at the end and has no RHS value.
      // E.g. some custom unary operator on a column.
      // For standard SQL comparison operators, this means an issue.
      if (operatorString != 'IS NULL' && operatorString != 'IS NOT NULL') {
        // print("Warning: RHS for operator '$operatorString' seems empty in '$fullExpressionString'");
      }
      return "";
    }

    return fullExpressionString.substring(rhsStartIndex).trim();
  }

  // --- Helper to parse a raw value string (from RHS) into a Dart type ---
  dynamic _parseRhsValue(String valueString, Type columnDartType, String? op) {
    if (valueString.isEmpty && (op == 'IS NULL' || op == 'IS NOT NULL')) return null; // No value for these

    if (valueString.toUpperCase() == 'NULL') return null;
    if (valueString.toUpperCase() == 'TRUE') return true;
    if (valueString.toUpperCase() == 'FALSE') return false;

    // Handle Serverpod's EscapedExpression output (typically single-quoted)
    if (valueString.startsWith("'") && valueString.endsWith("'")) {
      String unquoted = valueString.substring(1, valueString.length - 1);
      // Unescape doubled single quotes 'foo''bar' -> foo'bar
      unquoted = unquoted.replaceAll("''", "'");

      if (columnDartType == DateTime) return DateTime.parse(unquoted);
      if (columnDartType == UuidValue) return UuidValue(unquoted);
      // For enums serialized by name and string-encoded
      if (columnDartType is Enum && columnDartType != String) return unquoted; // Caller needs to map to Enum value
      return unquoted; // Default to string if specific type not matched
    }

    if (columnDartType == int) return int.tryParse(valueString);
    if (columnDartType == double) return double.tryParse(valueString);
    if (columnDartType == BigInt) return BigInt.tryParse(valueString);
    if (columnDartType == Duration) { // Assuming duration stored as int (microseconds)
      final intVal = int.tryParse(valueString);
      return (intVal != null) ? Duration(microseconds: intVal) : null;
    }


    // For enums serialized by index (will be plain numbers)
    if (columnDartType is Enum && int.tryParse(valueString) != null) {
      return int.parse(valueString); // Caller needs to map index to Enum value
    }

    // If it's none of the above, it might be an unquoted string or an unhandled type.
    // Or, if comparing column to column, this would be the other column's name.
    // For now, we assume values are literals.
    if (columnDartType == String) return valueString; // Unquoted string literal

    throw FormatException(
        "Could not parse RHS value string '$valueString' for Dart type $columnDartType");
  }

  List<dynamic> _parseRhsListValue(String listValueString, Type elementDartType) {
    if (!listValueString.startsWith("(") || !listValueString.endsWith(")")) {
      throw FormatException("RHS list value string for IN clause must be enclosed in parentheses: '$listValueString'");
    }
    final String innerContent = listValueString.substring(1, listValueString.length - 1);
    if (innerContent.isEmpty) return [];

    // This split is naive. A proper CSV parser is needed for robust handling of
    // strings containing commas. Serverpod's toString for SetColumnExpression typically
    // joins elements that are already stringified (e.g. "'val1'", "123").
    return innerContent.split(',').map((s) => _parseRhsValue(s.trim(), elementDartType, null)).toList();
  }


  // --- Main recursive function to apply expressions ---
  PostgrestFilterBuilder applyExpression(
      PostgrestFilterBuilder builder,
      Expression expr,
      Table table, {
        bool isNot = false,
      }) {
    if (expr is Constant) {
      // Constant.bool(true) -> 'TRUE', Constant.bool(false) -> 'FALSE'
      // Constant.nullValue -> 'NULL'
      // These are usually RHS, but if a whole filter is Constant.bool(false),
      // it means "match nothing". If Constant.bool(true), "match everything" (no filter).
      String constStr = expr.toString();
      if (constStr == 'TRUE') {
        return isNot ? builder.neq(table.id.columnName, table.id.columnName) : builder; // Effectively FALSE or TRUE
      } else if (constStr == 'FALSE') {
        return isNot ? builder : builder.neq(table.id.columnName, (table.id).columnName); // Effectively TRUE or FALSE
      }
      // Other constants are not standalone filters.
      throw ArgumentError('Standalone Constant expression (not bool) not supported as a full filter: $expr');
    }

    if (expr is NotExpression) {
      return applyExpression(builder, expr.subExpression, table, isNot: !isNot);
    }

    // _AndExpression and _OrExpression are private, but they extend TwoPartExpression
    if (expr is TwoPartExpression) {
      final leftExpr = expr.subExpressions[0];
      final rightExpr = expr.subExpressions[1];

      // For Supabase `and` and `or` filters, we need string representations.
      String leftFilterStr = _buildFilterString(leftExpr, table);
      String rightFilterStr = _buildFilterString(rightExpr, table);

      // Filter out empty strings which mean "true" or no-op for that sub-expression
      final filters = [leftFilterStr, rightFilterStr].where((s) => s.isNotEmpty).toList();
      if (filters.isEmpty) return isNot ? builder.neq((table.id).columnName, (table.id).columnName) : builder; // All true -> (NOT TRUE = FALSE) or TRUE

      final combinedFilter = filters.join(',');

      if (expr.operator == 'AND') {
        return isNot ? builder.filter('not.and', '(', combinedFilter) : builder.filter('and', '(', combinedFilter);
      } else if (expr.operator == 'OR') {
        return isNot ? builder.filter('not.or', '(', combinedFilter) : builder.or(combinedFilter);
      }
    }

    if (expr is ColumnExpression) {
      final columnName = expr.column.columnName;
      final columnType = expr.column.type; // Dart type of the column
      final operator = expr.operator;

      // Apply `isNot` to the operation
      PostgrestFilterBuilder filterBuilder = builder;// isNot ? builder.not : builder.isFilter;

      if (operator == 'IS NULL') {
        return filterBuilder.isFilter(columnName, null);
      } else if (operator == 'IS NOT NULL') {
        // isNot=true with IS NOT NULL means NOT (IS NOT NULL) -> IS NULL
        // isNot=false with IS NOT NULL means IS NOT NULL
        return isNot ? builder.isFilter(columnName, null) : builder.not(columnName, 'is', null);
      }

      // For other operators, we need the RHS value by parsing expr.toString()
      String rhsString = _extractRhsString(expr);

      if (operator == '=') {
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        return filterBuilder.eq(columnName, value);
      } else if (operator == '!=') {
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        return filterBuilder.neq(columnName, value);
      } else if (operator == '>') {
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        return filterBuilder.gt(columnName, value);
      } else if (operator == '>=') {
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        return filterBuilder.gte(columnName, value);
      } else if (operator == '<') {
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        return filterBuilder.lt(columnName, value);
      } else if (operator == '<=') {
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        return filterBuilder.lte(columnName, value);
      } else if (operator == 'LIKE') {
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        return filterBuilder.like(columnName, value as String);
      } else if (operator == 'ILIKE') {
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        return filterBuilder.ilike(columnName, value as String);
      } else if (operator == 'NOT LIKE') { // Serverpod: (NOT LIKE value) OR (IS NULL)
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        String filterStr = '$columnName.not.like.${_formatSupabaseValue(value)},$columnName.is.null';
        return isNot ? builder.filter('not.or', '(', filterStr) : builder.or(filterStr);
      } else if (operator == 'NOT ILIKE') { // Serverpod: (NOT ILIKE value) OR (IS NULL)
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        String filterStr = '$columnName.not.ilike.${_formatSupabaseValue(value)},$columnName.is.null';
        return isNot ? builder.filter('not.or', '(', filterStr) : builder.or(filterStr);
      } else if (operator == 'IN') {
        List<dynamic> values = _parseRhsListValue(rhsString, columnType);
        return filterBuilder.inFilter(columnName, values);
      } else if (operator == 'NOT IN') { // Serverpod: (NOT IN values) OR (IS NULL)
        List<dynamic> values = _parseRhsListValue(rhsString, columnType);
        final formattedValues = values.map(_formatSupabaseValue).join(',');
        String filterStr = '$columnName.not.in.($formattedValues),$columnName.is.null';
        return isNot ? builder.filter('not.or', '(', filterStr) : builder.or(filterStr);
      } else if (operator == 'BETWEEN') {
        // rhsString for BETWEEN is "value1 AND value2"
        var parts = rhsString.split(RegExp(r'\s+AND\s+', caseSensitive: false));
        if (parts.length == 2) {
          dynamic minVal = _parseRhsValue(parts[0], columnType, operator);
          dynamic maxVal = _parseRhsValue(parts[1], columnType, operator);
          if (isNot) { // NOT (BETWEEN min AND max)  =>  < min OR > max
            return builder.or(
                '$columnName.lt.${_formatSupabaseValue(minVal)},$columnName.gt.${_formatSupabaseValue(maxVal)}');
          }
          return builder.gte(columnName, minVal).lte(columnName, maxVal);
        }
      } else if (operator == 'NOT BETWEEN') {
        var parts = rhsString.split(RegExp(r'\s+AND\s+', caseSensitive: false));
        if (parts.length == 2) {
          dynamic minVal = _parseRhsValue(parts[0], columnType, operator);
          dynamic maxVal = _parseRhsValue(parts[1], columnType, operator);
          if (isNot) { // NOT (NOT BETWEEN min AND max) => BETWEEN min AND max
            return builder.gte(columnName, minVal).lte(columnName, maxVal);
          }
          return builder.or(
              '$columnName.lt.${_formatSupabaseValue(minVal)},$columnName.gt.${_formatSupabaseValue(maxVal)}');
        }
      } else if (operator == 'IS DISTINCT FROM') {
        dynamic value = _parseRhsValue(rhsString, columnType, operator);
        // Supabase .filter() for IS DISTINCT FROM
        return ((isNot ? builder.not : builder) as PostgrestFilterBuilder).filter(columnName, 'isdistinct', value);
      }
    }

    throw UnimplementedError('Expression type ${expr.runtimeType} with isNot=$isNot not supported yet. Expr: ${expr.toString()}');
  }

  // --- Helper to build filter strings for and_() and or() internal use ---
  String _buildFilterString(Expression expr, Table table, {bool topLevelNot = false}) {
    if (expr is Constant) {
      String constStr = expr.toString();
      if (constStr == 'TRUE') return topLevelNot ? 'id.is.null,id.not.is.null' : ''; // FALSE or TRUE (empty means true)
      if (constStr == 'FALSE') return topLevelNot ? '' : 'id.is.null,id.not.is.null'; // TRUE or FALSE
      throw ArgumentError("Cannot convert non-boolean Constant to filter string component.");
    }
    if (expr is NotExpression) {
      return _buildFilterString(expr.subExpression, table, topLevelNot: !topLevelNot);
    }

    String opPrefix = topLevelNot ? 'not.' : '';

    if (expr is TwoPartExpression) {
      String left = _buildFilterString(expr.subExpressions[0], table); // topLevelNot is handled by opPrefix for the combined expression
      String right = _buildFilterString(expr.subExpressions[1], table);

      final filters = [left, right].where((s) => s.isNotEmpty).toList();
      if (filters.isEmpty) return topLevelNot ? 'id.is.null,id.not.is.null' : '';

      final combined = filters.join(',');

      if (expr.operator == 'AND') return '${opPrefix}and($combined)';
      if (expr.operator == 'OR') return '${opPrefix}or($combined)';
    }

    if (expr is ColumnExpression) {
      final columnName = expr.column.columnName;
      final columnType = expr.column.type;
      final operator = expr.operator;
      String rhsString = _extractRhsString(expr);

      if (operator == 'IS NULL') return '$columnName.is.${topLevelNot ? "not.null" : "null"}';
      if (operator == 'IS NOT NULL') return '$columnName.is.${topLevelNot ? "null" : "not.null"}';

      dynamic value; // Parsed value
      List<dynamic>? valuesList; // For IN/NOT IN

      if (operator == 'IN' || operator == 'NOT IN') {
        valuesList = _parseRhsListValue(rhsString, columnType);
      } else if (operator == 'BETWEEN' || operator == 'NOT BETWEEN') {
        // Value parsing happens inside specific logic for between
      }
      else {
        value = _parseRhsValue(rhsString, columnType, operator);
      }

      if (operator == '=') return '$opPrefix$columnName.eq.${_formatSupabaseValue(value)}';
      if (operator == '!=') return '$opPrefix$columnName.neq.${_formatSupabaseValue(value)}';
      if (operator == '>') return '$opPrefix$columnName.gt.${_formatSupabaseValue(value)}';
      if (operator == '>=') return '$opPrefix$columnName.gte.${_formatSupabaseValue(value)}';
      if (operator == '<') return '$opPrefix$columnName.lt.${_formatSupabaseValue(value)}';
      if (operator == '<=') return '$opPrefix$columnName.lte.${_formatSupabaseValue(value)}';
      if (operator == 'LIKE') return '$opPrefix$columnName.like.${_formatSupabaseValue(value)}';
      if (operator == 'ILIKE') return '$opPrefix$columnName.ilike.${_formatSupabaseValue(value)}';
      if (operator == 'IN') {
        final formatted = valuesList!.map(_formatSupabaseValue).join(',');
        return '$opPrefix$columnName.in.($formatted)';
      }
      // Serverpod's complex NOT LIKE / NOT ILIKE / NOT IN (with OR IS NULL)
      if (operator == 'NOT LIKE') {
        value = _parseRhsValue(rhsString, columnType, operator); // re-parse for this specific case
        String filter = 'or($columnName.not.like.${_formatSupabaseValue(value)},$columnName.is.null)';
        return topLevelNot ? 'not.($filter)' : filter;
      }
      if (operator == 'NOT ILIKE') {
        value = _parseRhsValue(rhsString, columnType, operator);
        String filter = 'or($columnName.not.ilike.${_formatSupabaseValue(value)},$columnName.is.null)';
        return topLevelNot ? 'not.($filter)' : filter;
      }
      if (operator == 'NOT IN') {
        // valuesList already parsed
        final formatted = valuesList!.map(_formatSupabaseValue).join(',');
        String filter = 'or($columnName.not.in.($formatted),$columnName.is.null)';
        return topLevelNot ? 'not.($filter)' : filter;
      }
      if (operator == 'BETWEEN') {
        var parts = rhsString.split(RegExp(r'\s+AND\s+', caseSensitive: false));
        dynamic minVal = _parseRhsValue(parts[0], columnType, operator);
        dynamic maxVal = _parseRhsValue(parts[1], columnType, operator);
        String filter = 'and($columnName.gte.${_formatSupabaseValue(minVal)},$columnName.lte.${_formatSupabaseValue(maxVal)})';
        // NOT (A AND B) -> NOT A OR NOT B
        if (topLevelNot) filter = 'or($columnName.lt.${_formatSupabaseValue(minVal)},$columnName.gt.${_formatSupabaseValue(maxVal)})';
        return filter;
      }
      if (operator == 'NOT BETWEEN') {
        var parts = rhsString.split(RegExp(r'\s+AND\s+', caseSensitive: false));
        dynamic minVal = _parseRhsValue(parts[0], columnType, operator);
        dynamic maxVal = _parseRhsValue(parts[1], columnType, operator);
        String filter = 'or($columnName.lt.${_formatSupabaseValue(minVal)},$columnName.gt.${_formatSupabaseValue(maxVal)})';
        // NOT (A OR B) -> NOT A AND NOT B
        if (topLevelNot) filter = 'and($columnName.gte.${_formatSupabaseValue(minVal)},$columnName.lte.${_formatSupabaseValue(maxVal)})';
        return filter;
      }
      if (operator == 'IS DISTINCT FROM') {
        value = _parseRhsValue(rhsString, columnType, operator);
        // This does not directly translate to a simple filter string for Supabase's `or`/`and` combinators.
        // `.filter(col, 'isdistinct', val)` is a direct builder method.
        // We'd need a way to represent this complex filter if it's part of an OR/AND string.
        // For simplicity, we might say IS DISTINCT FROM is not supported inside OR/AND string combinations directly.
        throw UnimplementedError("IS DISTINCT FROM cannot be reliably converted to a filter string component for OR/AND.");
      }
    }
    throw UnimplementedError('Cannot build filter string for ${expr.runtimeType}. Expr: ${expr.toString()}');
  }

  // --- Helper to format values for Supabase filter strings (used in or/and) ---
  String _formatSupabaseValue(dynamic value) {
    if (value == null) return 'null'; // Supabase client handles null appropriately in direct methods
    // For string construction, 'null' keyword is used.
    if (value is String) {
      // For Supabase filter strings, strings are typically bare or quoted if they contain special chars.
      // The Supabase client library handles quoting for .eq('col', 'my value with space').
      // When building strings for .or(), .and_() this needs care. PostgREST syntax is `col=eq.my%20value`.
      // For safety, let's assume values in .or() / .and() strings are simple or pre-formatted.
      // Supabase's JS client forms `column=eq.value` not `column.eq.value`.
      // But `dart:supabase` uses `column.eq.value` for `or` and `and` string parameters.
      return value.toString().replaceAll(',', '%2C'); // Basic encoding for commas in values
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is UuidValue) return value.uuid;
    if (value is Enum) return value.name; // Assuming byName, adjust if byIndex
    return value.toString();
  }
}