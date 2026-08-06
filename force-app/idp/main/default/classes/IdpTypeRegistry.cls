/**
 * Resolves an IDP_Value_Type__mdt config to the IValueType instance that
 * implements it: built-in kinds map to the singletons in IdpValueTypes,
 * Kind = Custom resolves Handler_Class__c with Type.forName (the same DI
 * convention as finding handlers). Instances are stateless and cached.
 *
 * Rules that name no value type get one auto-derived from the target
 * field's describe — strict by design: numbers must parse deterministically,
 * dates are ISO. Anything looser is an explicit admin choice.
 */
public inherited sharing class IdpTypeRegistry {
  private static Map<String, IValueType> builtIns;
  private static Map<String, IValueType> customInstances = new Map<String, IValueType>();

  public static IValueType resolve(IdpValueTypes.Config cfg) {
    if (cfg.kind == IdpValueTypes.KIND_CUSTOM) {
      return custom(cfg.handlerClass);
    }
    IValueType type = builtIn(cfg.kind);
    if (type == null) {
      throw new IdpValueTypes.TypeException(
        'Value type ' + cfg.name + ' has unknown kind "' + cfg.kind + '".'
      );
    }
    return type;
  }

  public static IValueType builtIn(String kind) {
    if (builtIns == null) {
      builtIns = new Map<String, IValueType>{
        IdpValueTypes.KIND_TEXT => new IdpValueTypes.TextType(),
        IdpValueTypes.KIND_NUMBER => new IdpValueTypes.NumberType(),
        IdpValueTypes.KIND_DATE => new IdpValueTypes.DateType(),
        IdpValueTypes.KIND_DATETIME => new IdpValueTypes.DatetimeType(),
        IdpValueTypes.KIND_BOOLEAN => new IdpValueTypes.BooleanType(),
        IdpValueTypes.KIND_PHONE => new IdpValueTypes.PhoneType(),
        IdpValueTypes.KIND_VALUE_MAP => new IdpValueTypes.ValueMapType(),
        IdpValueTypes.KIND_REGEX => new IdpValueTypes.RegexType()
      };
    }
    return builtIns.get(kind);
  }

  /** Strict default config for a rule without an explicit value type. */
  public static IdpValueTypes.Config autoConfig(
    Schema.DescribeFieldResult field
  ) {
    IdpValueTypes.Config cfg = new IdpValueTypes.Config();
    switch on field.getType() {
      when BOOLEAN {
        cfg.kind = IdpValueTypes.KIND_BOOLEAN;
      }
      when DATE {
        cfg.kind = IdpValueTypes.KIND_DATE; // ISO only by default
      }
      when DATETIME {
        cfg.kind = IdpValueTypes.KIND_DATETIME;
      }
      when DOUBLE, CURRENCY, PERCENT, INTEGER, LONG {
        cfg.kind = IdpValueTypes.KIND_NUMBER;
      }
      when PHONE {
        cfg.kind = IdpValueTypes.KIND_PHONE;
      }
      when else {
        cfg.kind = IdpValueTypes.KIND_TEXT;
      }
    }
    cfg.name = 'auto:' + cfg.kind;
    return cfg;
  }

  private static IValueType custom(String className) {
    if (String.isBlank(className)) {
      throw new IdpValueTypes.TypeException(
        'A Custom value type needs a Handler Class.'
      );
    }
    if (customInstances.containsKey(className)) {
      return customInstances.get(className);
    }
    Type handlerType = Type.forName(className);
    if (handlerType == null) {
      throw new IdpValueTypes.TypeException(
        'Value type handler class "' + className + '" was not found.'
      );
    }
    Object instance;
    try {
      instance = handlerType.newInstance();
    } catch (Exception e) {
      throw new IdpValueTypes.TypeException(
        'Value type handler "' +
          className +
          '" could not be instantiated: ' +
          e.getMessage()
      );
    }
    if (!(instance instanceof IValueType)) {
      throw new IdpValueTypes.TypeException(
        'Value type handler "' +
          className +
          '" does not implement IValueType.'
      );
    }
    customInstances.put(className, (IValueType) instance);
    return (IValueType) instance;
  }
}
