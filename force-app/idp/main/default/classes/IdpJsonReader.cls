/**
 * Reads values out of a deserialized JSON structure (the result of
 * JSON.deserializeUntyped) using dot notation with optional array indexes,
 * e.g. "applicant.dateOfBirth" or "beneficiaries[0].address.city".
 *
 * Understands confidence envelopes: an IDP service that reports per-field
 * OCR confidence can wrap any node as {"value": ..., "confidence": 0.93}.
 * The envelope is transparent to paths — the value is unwrapped wherever
 * one is met, and the innermost confidence travels with the result so
 * rules can gate on Min_Confidence__c.
 *
 * A missing path reads as null — callers treat that as "value absent",
 * never as an error.
 */
public inherited sharing class IdpJsonReader {
  private static final String KEY_VALUE = 'value';
  private static final String KEY_CONFIDENCE = 'confidence';

  /** A read value together with the confidence its envelope carried, if any. */
  public class ValueAt {
    public Object value;
    public Decimal confidence;
  }

  /** Plain read — envelopes unwrapped, confidence discarded. */
  public static Object read(Object root, String path) {
    return readWithConfidence(root, path).value;
  }

  public static ValueAt readWithConfidence(Object root, String path) {
    ValueAt result = new ValueAt();
    if (root == null || String.isBlank(path)) {
      return result;
    }
    Object current = unwrap(root, result);
    for (String token : path.split('\\.')) {
      String name = token.substringBefore('[');
      if (String.isNotBlank(name)) {
        if (!(current instanceof Map<String, Object>)) {
          return blank(result);
        }
        current = unwrap(((Map<String, Object>) current).get(name), result);
      }
      // Apply each [n] suffix in order (supports nested lists, a[0][1]).
      String indexes = token.substringAfter('[');
      while (token.contains('[') && String.isNotBlank(indexes)) {
        String indexText = indexes.substringBefore(']');
        Integer index;
        try {
          index = Integer.valueOf(indexText);
        } catch (Exception e) {
          return blank(result);
        }
        if (
          !(current instanceof List<Object>) ||
          index < 0 ||
          index >= ((List<Object>) current).size()
        ) {
          return blank(result);
        }
        current = unwrap(((List<Object>) current)[index], result);
        indexes = indexes.substringAfter('[');
      }
      if (current == null) {
        return blank(result);
      }
    }
    result.value = current;
    return result;
  }

  /** Steps through a confidence envelope, keeping the innermost confidence. */
  private static Object unwrap(Object node, ValueAt result) {
    while (isEnvelope(node)) {
      Map<String, Object> envelope = (Map<String, Object>) node;
      Decimal confidence = asDecimal(envelope.get(KEY_CONFIDENCE));
      if (confidence != null) {
        result.confidence = confidence;
      }
      node = envelope.get(KEY_VALUE);
    }
    return node;
  }

  /** Only the exact two-key {value, confidence} shape is an envelope, so a
   *  legitimate business field named "value" can never be swallowed. */
  private static Boolean isEnvelope(Object node) {
    if (!(node instanceof Map<String, Object>)) {
      return false;
    }
    Map<String, Object> candidate = (Map<String, Object>) node;
    return candidate.size() == 2 &&
      candidate.containsKey(KEY_VALUE) &&
      candidate.containsKey(KEY_CONFIDENCE) &&
      (candidate.get(KEY_CONFIDENCE) == null ||
      asDecimal(candidate.get(KEY_CONFIDENCE)) != null);
  }

  private static Decimal asDecimal(Object value) {
    if (value instanceof Decimal) {
      return (Decimal) value;
    }
    if (value instanceof Integer) {
      return Decimal.valueOf((Integer) value);
    }
    if (value instanceof Long) {
      return Decimal.valueOf((Long) value);
    }
    if (value instanceof Double) {
      return Decimal.valueOf((Double) value);
    }
    return null;
  }

  private static ValueAt blank(ValueAt result) {
    result.value = null;
    return result;
  }
}
