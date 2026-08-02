/**
 * Reads values out of a deserialized JSON structure (the result of
 * JSON.deserializeUntyped) using dot notation with optional array indexes,
 * e.g. "applicant.dateOfBirth" or "beneficiaries[0].address.city".
 *
 * Returns null when the path does not exist — callers treat that as
 * "value absent", never as an error.
 */
public inherited sharing class JsonPathReader {
  public static Object read(Object root, String path) {
    if (root == null || String.isBlank(path)) {
      return null;
    }
    Object current = root;
    for (String token : path.split('\\.')) {
      String name = token.substringBefore('[');
      if (String.isNotBlank(name)) {
        if (!(current instanceof Map<String, Object>)) {
          return null;
        }
        current = ((Map<String, Object>) current).get(name);
      }
      // Apply each [n] suffix in order (supports nested lists, a[0][1]).
      String indexes = token.substringAfter('[');
      while (token.contains('[') && String.isNotBlank(indexes)) {
        String indexText = indexes.substringBefore(']');
        Integer index;
        try {
          index = Integer.valueOf(indexText);
        } catch (Exception e) {
          return null;
        }
        if (
          !(current instanceof List<Object>) ||
          index < 0 ||
          index >= ((List<Object>) current).size()
        ) {
          return null;
        }
        current = ((List<Object>) current)[index];
        indexes = indexes.substringAfter('[');
      }
      if (current == null) {
        return null;
      }
    }
    return current;
  }
}
