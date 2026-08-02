/**
 * Converts a raw JSON value into the Apex type the target field expects,
 * driven by the field's describe. Throws CoercionException with a
 * user-readable message when the value cannot be converted, so the caller
 * can report it per rule instead of failing the whole run.
 *
 * The optional transform hint currently applies to Date fields:
 * "yyyy-MM-dd" (default), "dd/MM/yyyy" or "MM/dd/yyyy".
 */
public inherited sharing class FieldValueCoercer {
  public class CoercionException extends Exception {
  }

  public static Object coerce(
    Schema.DescribeFieldResult field,
    Object raw,
    String transform
  ) {
    if (raw == null) {
      return null;
    }
    switch on field.getType() {
      when BOOLEAN {
        return toBoolean(raw);
      }
      when DATE {
        return toDate(raw, transform);
      }
      when DATETIME {
        return toDateTime(raw);
      }
      when DOUBLE, CURRENCY, PERCENT {
        return toDecimal(raw);
      }
      when INTEGER, LONG {
        return toDecimal(raw).intValue();
      }
      when PICKLIST {
        return toPicklist(field, raw);
      }
      when else {
        // STRING, TEXTAREA, EMAIL, PHONE, URL, ID, REFERENCE,
        // MULTIPICKLIST: pass through as text.
        return String.valueOf(raw);
      }
    }
  }

  private static Boolean toBoolean(Object raw) {
    if (raw instanceof Boolean) {
      return (Boolean) raw;
    }
    String s = String.valueOf(raw).trim().toLowerCase();
    if (s == 'true' || s == 'yes' || s == 'y' || s == '1') {
      return true;
    }
    if (s == 'false' || s == 'no' || s == 'n' || s == '0') {
      return false;
    }
    throw new CoercionException('"' + raw + '" is not a boolean value.');
  }

  private static Decimal toDecimal(Object raw) {
    if (raw instanceof Decimal) {
      return (Decimal) raw;
    }
    // Strip thousand separators and currency noise: "R 1,234.56" → 1234.56
    String s = String.valueOf(raw).replaceAll('[^0-9.\\-]', '').trim();
    try {
      return Decimal.valueOf(s);
    } catch (Exception e) {
      throw new CoercionException('"' + raw + '" is not a number.');
    }
  }

  private static Date toDate(Object raw, String transform) {
    String s = String.valueOf(raw).trim();
    try {
      if (transform == 'dd/MM/yyyy' || transform == 'MM/dd/yyyy') {
        List<String> parts = s.split('[/\\-]');
        if (parts.size() != 3) {
          throw new CoercionException('bad format');
        }
        Integer first = Integer.valueOf(parts[0]);
        Integer second = Integer.valueOf(parts[1]);
        Integer year = Integer.valueOf(parts[2]);
        return transform == 'dd/MM/yyyy'
          ? Date.newInstance(year, second, first)
          : Date.newInstance(year, first, second);
      }
      return Date.valueOf(s);
    } catch (Exception e) {
      throw new CoercionException(
        '"' +
          raw +
          '" is not a valid date' +
          (String.isBlank(transform) ? '' : ' (' + transform + ')') +
          '.'
      );
    }
  }

  private static Datetime toDateTime(Object raw) {
    try {
      // JSON.deserialize handles ISO 8601 including timezone offsets.
      return (Datetime) JSON.deserialize(
        '"' + String.valueOf(raw).trim() + '"',
        Datetime.class
      );
    } catch (Exception e) {
      throw new CoercionException('"' + raw + '" is not a valid date/time.');
    }
  }

  private static String toPicklist(
    Schema.DescribeFieldResult field,
    Object raw
  ) {
    String s = String.valueOf(raw).trim();
    if (field.isRestrictedPicklist()) {
      for (Schema.PicklistEntry entry : field.getPicklistValues()) {
        if (entry.isActive() && entry.getValue() == s) {
          return s;
        }
      }
      throw new CoercionException(
        '"' +
          s +
          '" is not an active value of picklist ' +
          field.getName() +
          '.'
      );
    }
    return s;
  }
}
