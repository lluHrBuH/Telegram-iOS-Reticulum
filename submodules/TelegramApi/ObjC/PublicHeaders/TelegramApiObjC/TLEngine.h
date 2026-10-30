#import <TelegramApiObjC/TLObject.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct TLReader {
    const uint8_t *_Nullable bytes;
    size_t length;
    size_t offset;
} TLReader;

typedef struct TLWriter {
    uint8_t *_Nullable bytes;
    size_t length;
    size_t capacity;
} TLWriter;

/// A function: its id, arguments (as a constructor) and the shape of its result.
typedef struct TLFunctionInfo {
    TLConstructorInfo constructor;
    TLFieldInfo result;
} TLFunctionInfo;

/// The function table entry of a generated argument object.
const TLFunctionInfo *TLObjectFunctionInfo(TLObject *object);

/// Parses a serialized function call (its id first, then the arguments as a constructor body) into
/// the same argument object the `Api.functions.*` builders make. Fails (NULL) on an unknown function
/// id (reported to the unknown-constructor handler) or a truncated body.
TLObject *_Nullable TLParseFunctionCall(TLReader *reader) NS_RETURNS_RETAINED;

/// Parses a response to `info`'s function: a boxed object, or a vector of objects/ints/longs/strings.
id _Nullable TLParseFunctionResult(TLReader *reader, const TLFunctionInfo *info) NS_RETURNS_RETAINED;

/// Parses the body of the constructor `constructorId` (already read). Fails (NULL) on
/// truncation, on an unknown id (reported to the unknown-constructor handler unless it is a
/// built-in primitive id), or when the constructor is not of `expectedTypeIndex`.
TLObject *_Nullable TLParseConstructor(TLReader *reader, int32_t constructorId, uint16_t expectedTypeIndex) NS_RETURNS_RETAINED;

/// Appends `object` (its id first when `boxed`) to `writer`.
void TLSerialize(TLObject *object, TLWriter *writer, bool boxed);
void TLWriterFree(TLWriter *writer);

void TLSetUnknownConstructorHandler(void (*_Nullable handler)(int32_t constructorId));

NS_ASSUME_NONNULL_END
