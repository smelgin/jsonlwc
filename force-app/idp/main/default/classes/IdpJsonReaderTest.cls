/**
 * Unit tests for path reading and confidence envelopes.
 */
@IsTest
private class IdpJsonReaderTest {
  /**
   * Deserializes a sample document the way the engine does.
   *
   * @param jsonText Document text.
   * @return Untyped structure the reader walks.
   */
  private static Object parse(String jsonText) {
    return JSON.deserializeUntyped(jsonText);
  }

  /**
   * Verifies dot paths and array indexes, and that an absent path is null.
   */
  @IsTest
  static void readsDotPathsAndIndexes() {
    Object root = parse('{"a": {"b": [{"c": "x"}, {"c": "y"}]}, "n": 5}');
    Assert.areEqual('y', IdpJsonReader.read(root, 'a.b[1].c'));
    Assert.areEqual(5, IdpJsonReader.read(root, 'n'));
    Assert.isNull(IdpJsonReader.read(root, 'a.b[9].c'));
    Assert.isNull(IdpJsonReader.read(root, 'a.missing'));
    Assert.isNull(IdpJsonReader.read(root, ''));
    Assert.isNull(IdpJsonReader.read(null, 'a'));
  }

  /**
   * Verifies that an enveloped leaf yields its value and its confidence.
   */
  @IsTest
  static void unwrapsConfidenceEnvelopes() {
    Object root = parse(
      '{"applicant": {"name": {"value": "Jane", "confidence": 0.93}}}'
    );
    IdpJsonReader.ValueAt read = IdpJsonReader.readWithConfidence(
      root,
      'applicant.name'
    );
    Assert.areEqual('Jane', read.value);
    Assert.areEqual(0.93, read.confidence);
  }

  /**
   * Verifies that a path walks through an envelope wrapping a whole
   * object, keeping the confidence met on the way.
   */
  @IsTest
  static void unwrapsEnvelopesMidPath() {
    // The whole applicant object is enveloped; the path walks through it.
    Object root = parse(
      '{"applicant": {"value": {"name": "Jane"}, "confidence": 0.8}}'
    );
    IdpJsonReader.ValueAt read = IdpJsonReader.readWithConfidence(
      root,
      'applicant.name'
    );
    Assert.areEqual('Jane', read.value);
    Assert.areEqual(
      0.8,
      read.confidence,
      'the envelope on the way through counts'
    );
  }

  /**
   * Verifies that nested envelopes report the innermost confidence.
   */
  @IsTest
  static void innermostConfidenceWins() {
    Object root = parse(
      '{"applicant": {"value": {"name": {"value": "Jane", "confidence": 0.6}}, "confidence": 0.9}}'
    );
    Assert.areEqual(
      0.6,
      IdpJsonReader.readWithConfidence(root, 'applicant.name').confidence
    );
  }

  /**
   * Verifies that an object merely containing a "value" key is read as
   * business data rather than unwrapped as an envelope.
   */
  @IsTest
  static void businessFieldsNamedValueAreNotSwallowed() {
    // Three keys — not the exact {value, confidence} shape, so no unwrap.
    Object root = parse(
      '{"item": {"value": 10, "confidence": 0.5, "label": "x"}}'
    );
    Assert.areEqual(10, IdpJsonReader.read(root, 'item.value'));
    IdpJsonReader.ValueAt read = IdpJsonReader.readWithConfidence(
      root,
      'item.value'
    );
    Assert.isNull(read.confidence, 'no envelope was involved');
  }
}
