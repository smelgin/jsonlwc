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
 *
 * @group IDP Engine
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpJsonReader {
  /** Envelope key holding the wrapped value. */
  private static final String KEY_VALUE = 'value';

  /** Envelope key holding the OCR confidence. */
  private static final String KEY_CONFIDENCE = 'confidence';

  /** A read value together with the confidence its envelope carried, if any. */
  public class ValueAt {
    /** Value found at the path, null when the path is absent. */
    public Object value;
    /** Innermost envelope confidence, null when the document carried none. */
    public Decimal confidence;
  }

  /**
   * Reads a path, unwrapping envelopes and discarding confidence.
   *
   * @param root Deserialized JSON structure to read from.
   * @param path Dot notation path, optionally with array indexes.
   * @return Value at the path, or null when the path is absent.
   */
  public static Object read(Object root, String path) {
    return readWithConfidence(root, path).value;
  }

  /**
   * Reads a path, keeping the confidence its envelopes reported.
   *
   * @param root Deserialized JSON structure to read from.
   * @param path Dot notation path, optionally with array indexes.
   * @return Value at the path plus the innermost confidence met on the way.
   */
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

  /**
   * Steps through nested confidence envelopes down to the real value.
   *
   * @param node Node that may be wrapped in one or more envelopes.
   * @param result Accumulator updated with the innermost confidence.
   * @return The unwrapped node.
   */
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

  /**
   * Decides whether a node is a confidence envelope.
   *
   * Only the exact two-key {value, confidence} shape qualifies, so a
   * legitimate business field named "value" can never be swallowed.
   *
   * @param node Node to inspect.
   * @return True when the node is an envelope around a value.
   */
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

  /**
   * Widens any JSON numeric to Decimal.
   *
   * @param value Node deserialized from the document.
   * @return Decimal form, or null when the node is not numeric.
   */
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

  /**
   * Reports an absent path while keeping any confidence already collected.
   *
   * @param result Accumulator built so far.
   * @return The same accumulator with its value cleared.
   */
  private static ValueAt blank(ValueAt result) {
    result.value = null;
    return result;
  }
}
