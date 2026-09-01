#include "cmfa_napi.h"

#include <array>
#include <cstdint>

extern "C" napi_status napi_get_prototype(napi_env env, napi_value object, napi_value *result);
extern "C" napi_status napi_strict_equals(napi_env env, napi_value lhs, napi_value rhs, bool *result);
extern "C" napi_status napi_get_all_property_names(napi_env env,
                                                   napi_value object,
                                                   napi_key_collection_mode key_mode,
                                                   napi_key_filter key_filter,
                                                   napi_key_conversion key_conversion,
                                                   napi_value *result);

namespace cmfa::nodeaddon {

namespace {

constexpr std::array<const char *, 4> kProxyContextKeys = {
    "profileHash",
    "revisionHash",
    "sessionHash",
    "generation",
};
constexpr std::array<const char *, 1> kDataClassPrototypeKeys = {
    "constructor",
};
constexpr size_t kProxyDelayJobIdBytes = 32;

template <size_t N>
bool validate_exact_own_keys(napi_env env,
                             napi_value object,
                             const std::array<const char *, N> &expected,
                             CoreErrorData *error,
                             const char *operation) {
  napi_value keys = nullptr;
  napi_status status = napi_get_all_property_names(
      env, object, napi_key_own_only, napi_key_all_properties, napi_key_keep_numbers, &keys);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }

  bool is_array = false;
  status = napi_is_array(env, keys, &is_array);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (!is_array) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  uint32_t length = 0;
  status = napi_get_array_length(env, keys, &length);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (length != expected.size()) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  std::array<bool, N> seen{};
  for (uint32_t index = 0; index < length; index += 1) {
    napi_value key_value = nullptr;
    status = napi_get_element(env, keys, index, &key_value);
    if (status != napi_ok) {
      *error = make_napi_failure(operation, status);
      return false;
    }

    napi_valuetype key_type = napi_undefined;
    status = napi_typeof(env, key_value, &key_type);
    if (status != napi_ok) {
      *error = make_napi_failure(operation, status);
      return false;
    }
    if (key_type != napi_string) {
      *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
      return false;
    }

    std::string key;
    if (!decode_utf8_string(env, key_value, &key, error, operation, true, CMFA_MAX_PATH_BYTES)) {
      return false;
    }
    bool matched = false;
    for (size_t expected_index = 0; expected_index < expected.size(); expected_index += 1) {
      if (key == expected[expected_index]) {
        seen[expected_index] = true;
        matched = true;
        break;
      }
    }
    if (!matched) {
      *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
      return false;
    }
  }

  for (bool flag : seen) {
    if (!flag) {
      *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
      return false;
    }
  }
  return true;
}

bool get_named_property_or_error(napi_env env,
                                 napi_value object,
                                 const char *name,
                                 napi_value *result,
                                 CoreErrorData *error,
                                 const char *operation) {
  const napi_status status = napi_get_named_property(env, object, name, result);
  if (status == napi_ok) {
    return true;
  }
  *error = make_napi_failure(operation, status);
  return false;
}

bool decode_boolean_value(napi_env env, napi_value value, bool *out, CoreErrorData *error, const char *operation) {
  napi_valuetype type = napi_undefined;
  napi_status status = napi_typeof(env, value, &type);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (type != napi_boolean) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  bool bool_value = false;
  status = napi_get_value_bool(env, value, &bool_value);
  if (status != napi_ok) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  *out = bool_value;
  return true;
}

bool validate_plain_object_prototype(napi_env env, napi_value value, CoreErrorData *error, const char *operation) {
  napi_value fresh_object = nullptr;
  napi_status status = napi_create_object(env, &fresh_object);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }

  napi_value prototype = nullptr;
  status = napi_get_prototype(env, value, &prototype);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }

  napi_value fresh_object_prototype = nullptr;
  status = napi_get_prototype(env, fresh_object, &fresh_object_prototype);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }

  bool matches_plain_object = false;
  status = napi_strict_equals(env, prototype, fresh_object_prototype, &matches_plain_object);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (!matches_plain_object) {
    napi_value null_value = nullptr;
    status = napi_get_null(env, &null_value);
    if (status != napi_ok) {
      *error = make_napi_failure(operation, status);
      return false;
    }
    bool prototype_is_null = false;
    status = napi_strict_equals(env, prototype, null_value, &prototype_is_null);
    if (status != napi_ok) {
      *error = make_napi_failure(operation, status);
      return false;
    }
    if (prototype_is_null) {
      *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
      return false;
    }

    napi_value prototype_parent = nullptr;
    status = napi_get_prototype(env, prototype, &prototype_parent);
    if (status != napi_ok) {
      *error = make_napi_failure(operation, status);
      return false;
    }
    bool inherits_plain_object = false;
    status = napi_strict_equals(env, prototype_parent, fresh_object_prototype, &inherits_plain_object);
    if (status != napi_ok) {
      *error = make_napi_failure(operation, status);
      return false;
    }
    if (!inherits_plain_object) {
      *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
      return false;
    }
    if (!validate_exact_own_keys(env, prototype, kDataClassPrototypeKeys, error, operation)) {
      return false;
    }
  }
  return true;
}

bool decode_uint64_value_local(napi_env env,
                               napi_value value,
                               uint64_t *out,
                               CoreErrorData *error,
                               const char *operation) {
  napi_valuetype type = napi_undefined;
  napi_status status = napi_typeof(env, value, &type);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (type != napi_number) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  int64_t raw_value = 0;
  status = napi_get_value_int64(env, value, &raw_value);
  if (status != napi_ok) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  double numeric_value = 0;
  status = napi_get_value_double(env, value, &numeric_value);
  if (status != napi_ok || numeric_value != static_cast<double>(raw_value)) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  if (raw_value <= 0) {
    *error = make_core_error(CMFA_OUT_OF_RANGE, operation);
    return false;
  }

  const uint64_t parsed = static_cast<uint64_t>(raw_value);
  if (parsed > kMaxJsSafeInteger) {
    *error = make_core_error(CMFA_OUT_OF_RANGE, operation);
    return false;
  }

  *out = parsed;
  return true;
}

bool is_lower_hex_hash(const std::string &value) {
  if (value.size() != 64) {
    return false;
  }
  for (char byte : value) {
    const bool numeric = byte >= '0' && byte <= '9';
    const bool lower_alpha = byte >= 'a' && byte <= 'f';
    if (!numeric && !lower_alpha) {
      return false;
    }
  }
  return true;
}

bool decode_hash_string(napi_env env,
                        napi_value value,
                        std::string *out,
                        CoreErrorData *error,
                        const char *operation) {
  if (!decode_utf8_string(env, value, out, error, operation, true, CMFA_MAX_PROXY_HASH_BYTES)) {
    return false;
  }
  if (!is_lower_hex_hash(*out)) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  return true;
}

bool next_utf8_code_point(std::string_view input, size_t *index, uint32_t *code_point) {
  if (*index >= input.size()) {
    return false;
  }

  const unsigned char lead = static_cast<unsigned char>(input[*index]);
  if (lead <= 0x7F) {
    *code_point = lead;
    *index += 1;
    return true;
  }

  const size_t remaining = input.size() - *index;
  if ((lead & 0xE0U) == 0xC0U) {
    if (remaining < 2) {
      return false;
    }
    const unsigned char b1 = static_cast<unsigned char>(input[*index + 1]);
    if ((b1 & 0xC0U) != 0x80U) {
      return false;
    }
    const uint32_t cp = (static_cast<uint32_t>(lead & 0x1FU) << 6U) | static_cast<uint32_t>(b1 & 0x3FU);
    if (cp < 0x80U) {
      return false;
    }
    *code_point = cp;
    *index += 2;
    return true;
  }

  if ((lead & 0xF0U) == 0xE0U) {
    if (remaining < 3) {
      return false;
    }
    const unsigned char b1 = static_cast<unsigned char>(input[*index + 1]);
    const unsigned char b2 = static_cast<unsigned char>(input[*index + 2]);
    if ((b1 & 0xC0U) != 0x80U || (b2 & 0xC0U) != 0x80U) {
      return false;
    }
    const uint32_t cp = (static_cast<uint32_t>(lead & 0x0FU) << 12U) |
                        (static_cast<uint32_t>(b1 & 0x3FU) << 6U) |
                        static_cast<uint32_t>(b2 & 0x3FU);
    if (cp < 0x800U || (cp >= 0xD800U && cp <= 0xDFFFU)) {
      return false;
    }
    *code_point = cp;
    *index += 3;
    return true;
  }

  if ((lead & 0xF8U) == 0xF0U) {
    if (remaining < 4) {
      return false;
    }
    const unsigned char b1 = static_cast<unsigned char>(input[*index + 1]);
    const unsigned char b2 = static_cast<unsigned char>(input[*index + 2]);
    const unsigned char b3 = static_cast<unsigned char>(input[*index + 3]);
    if ((b1 & 0xC0U) != 0x80U || (b2 & 0xC0U) != 0x80U || (b3 & 0xC0U) != 0x80U) {
      return false;
    }
    const uint32_t cp = (static_cast<uint32_t>(lead & 0x07U) << 18U) |
                        (static_cast<uint32_t>(b1 & 0x3FU) << 12U) |
                        (static_cast<uint32_t>(b2 & 0x3FU) << 6U) |
                        static_cast<uint32_t>(b3 & 0x3FU);
    if (cp < 0x10000U || cp > 0x10FFFFU) {
      return false;
    }
    *code_point = cp;
    *index += 4;
    return true;
  }

  return false;
}

bool contains_unicode_control(std::string_view input) {
  size_t index = 0;
  while (index < input.size()) {
    uint32_t code_point = 0;
    if (!next_utf8_code_point(input, &index, &code_point)) {
      return true;
    }
    if (code_point <= 0x1FU || (code_point >= 0x7FU && code_point <= 0x9FU)) {
      return true;
    }
  }
  return false;
}

bool decode_proxy_name(napi_env env,
                       napi_value value,
                       std::string *out,
                       CoreErrorData *error,
                       const char *operation) {
  if (!decode_utf8_string(
          env, value, out, error, operation, true, static_cast<size_t>(CMFA_MAX_PROXY_NAME_UTF8_BYTES + 1U))) {
    return false;
  }
  if (contains_unicode_control(*out)) {
    *error = make_core_error(CMFA_INVALID_UTF8, operation);
    return false;
  }
  return true;
}

bool is_lower_hex_job_id(std::string_view value) {
  if (value.size() != kProxyDelayJobIdBytes) {
    return false;
  }
  for (char byte : value) {
    const bool numeric = byte >= '0' && byte <= '9';
    const bool lower_alpha = byte >= 'a' && byte <= 'f';
    if (!numeric && !lower_alpha) {
      return false;
    }
  }
  return true;
}

bool decode_proxy_delay_job_id(napi_env env,
                               napi_value value,
                               std::string *out,
                               CoreErrorData *error,
                               const char *operation) {
  if (!decode_utf8_string(env, value, out, error, operation, true, kProxyDelayJobIdBytes + 2U)) {
    return false;
  }
  if (!is_lower_hex_job_id(*out)) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  return true;
}

bool decode_proxy_context(napi_env env, napi_value value, OwnedProxyQueryContext *out, CoreErrorData *error, const char *operation) {
  napi_valuetype type = napi_undefined;
  napi_status status = napi_typeof(env, value, &type);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (type != napi_object) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  if (!validate_plain_object_prototype(env, value, error, operation)) {
    return false;
  }
  if (!validate_exact_own_keys(env, value, kProxyContextKeys, error, operation)) {
    return false;
  }

  napi_value profile_hash = nullptr;
  napi_value revision_hash = nullptr;
  napi_value session_hash = nullptr;
  napi_value generation = nullptr;
  if (!get_named_property_or_error(env, value, "profileHash", &profile_hash, error, operation) ||
      !get_named_property_or_error(env, value, "revisionHash", &revision_hash, error, operation) ||
      !get_named_property_or_error(env, value, "sessionHash", &session_hash, error, operation) ||
      !get_named_property_or_error(env, value, "generation", &generation, error, operation)) {
    return false;
  }

  if (!decode_hash_string(env, profile_hash, &out->profile_hash, error, operation) ||
      !decode_hash_string(env, revision_hash, &out->revision_hash, error, operation) ||
      !decode_uint64_value_local(env, generation, &out->generation, error, operation)) {
    return false;
  }

  napi_valuetype session_type = napi_undefined;
  status = napi_typeof(env, session_hash, &session_type);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (session_type == napi_null) {
    out->session_hash.clear();
    out->has_session = false;
    return true;
  }

  if (!decode_hash_string(env, session_hash, &out->session_hash, error, operation)) {
    return false;
  }
  out->has_session = true;
  return true;
}

} // namespace

#if defined(CMFA_NAPI_PROXY_HOST_STUBS)
extern "C" napi_status napi_get_all_property_names(napi_env env,
                                                   napi_value object,
                                                   napi_key_collection_mode,
                                                   napi_key_filter,
                                                   napi_key_conversion,
                                                   napi_value *result) {
  return napi_get_property_names(env, object, result);
}

extern "C" napi_status napi_get_prototype(napi_env env, napi_value, napi_value *result) {
  return napi_get_null(env, result);
}

extern "C" napi_status napi_strict_equals(napi_env, napi_value lhs, napi_value rhs, bool *result) {
  *result = lhs == rhs;
  return napi_ok;
}

cmfa_status fail_proxy_host_stub(cmfa_json_buffer *output, cmfa_error *error) {
  if (output != nullptr) {
    output->length = 0;
    if (output->data != nullptr && output->capacity > 0) {
      output->data[0] = '\0';
    }
  }
  if (error != nullptr) {
    error->code = CMFA_CORE_UNAVAILABLE;
    error->length = 0;
    if (error->message != nullptr && error->capacity > 0) {
      error->message[0] = '\0';
    }
  }
  return CMFA_CORE_UNAVAILABLE;
}

extern "C" cmfa_status cmfa_proxy_groups(const cmfa_proxy_query_context *, uint8_t, cmfa_json_buffer *output, cmfa_error *error) {
  return fail_proxy_host_stub(output, error);
}

extern "C" cmfa_status cmfa_proxy_group(const cmfa_proxy_query_context *,
                                        const char *,
                                        cmfa_json_buffer *output,
                                        cmfa_error *error) {
  return fail_proxy_host_stub(output, error);
}

extern "C" cmfa_status cmfa_proxy_select(const cmfa_proxy_query_context *,
                                         const char *,
                                         const char *,
                                         cmfa_json_buffer *output,
                                         cmfa_error *error) {
  return fail_proxy_host_stub(output, error);
}

extern "C" cmfa_status cmfa_proxy_delay_start(const cmfa_proxy_query_context *,
                                              const char *,
                                              cmfa_json_buffer *output,
                                              cmfa_error *error) {
  return fail_proxy_host_stub(output, error);
}

extern "C" cmfa_status cmfa_proxy_delay_snapshot(const char *, cmfa_json_buffer *output, cmfa_error *error) {
  return fail_proxy_host_stub(output, error);
}

extern "C" cmfa_status cmfa_proxy_delay_cancel(const char *, cmfa_json_buffer *output, cmfa_error *error) {
  return fail_proxy_host_stub(output, error);
}
#endif

napi_value query_proxy_groups(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "queryProxyGroups", status);
      return nullptr;
    }
    if (argc != 2) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "queryProxyGroups"));
      return nullptr;
    }

    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "queryProxyGroups"));
      return nullptr;
    }

    AsyncInput input;
    input.op = AsyncOp::PROXY_GROUPS;
    CoreErrorData error;
    if (!decode_proxy_context(env, argv[0], &input.proxy_query_context, &error, "queryProxyGroups") ||
        !decode_boolean_value(env, argv[1], &input.proxy_selectable_only, &error, "queryProxyGroups")) {
      throw_core_error(env, error);
      return nullptr;
    }

    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "queryProxyGroups", napi_generic_failure);
    return nullptr;
  }
}

napi_value query_proxy_group(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "queryProxyGroup", status);
      return nullptr;
    }
    if (argc != 2) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "queryProxyGroup"));
      return nullptr;
    }

    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "queryProxyGroup"));
      return nullptr;
    }

    AsyncInput input;
    input.op = AsyncOp::PROXY_GROUP;
    CoreErrorData error;
    if (!decode_proxy_context(env, argv[0], &input.proxy_query_context, &error, "queryProxyGroup") ||
        !decode_proxy_name(env, argv[1], &input.proxy_group_name, &error, "queryProxyGroup")) {
      throw_core_error(env, error);
      return nullptr;
    }

    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "queryProxyGroup", napi_generic_failure);
    return nullptr;
  }
}

napi_value select_proxy(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "selectProxy", status);
      return nullptr;
    }
    if (argc != 3) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "selectProxy"));
      return nullptr;
    }

    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "selectProxy"));
      return nullptr;
    }

    AsyncInput input;
    input.op = AsyncOp::PROXY_SELECT;
    CoreErrorData error;
    if (!decode_proxy_context(env, argv[0], &input.proxy_query_context, &error, "selectProxy") ||
        !decode_proxy_name(env, argv[1], &input.proxy_group_name, &error, "selectProxy") ||
        !decode_proxy_name(env, argv[2], &input.proxy_member_name, &error, "selectProxy")) {
      throw_core_error(env, error);
      return nullptr;
    }

    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "selectProxy", napi_generic_failure);
    return nullptr;
  }
}

napi_value start_proxy_delay_test(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "startProxyDelayTest", status);
      return nullptr;
    }
    if (argc != 2) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "startProxyDelayTest"));
      return nullptr;
    }

    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "startProxyDelayTest"));
      return nullptr;
    }

    AsyncInput input;
    input.op = AsyncOp::PROXY_DELAY_START;
    CoreErrorData error;
    if (!decode_proxy_context(env, argv[0], &input.proxy_query_context, &error, "startProxyDelayTest") ||
        !decode_proxy_name(env, argv[1], &input.proxy_group_name, &error, "startProxyDelayTest")) {
      throw_core_error(env, error);
      return nullptr;
    }

    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "startProxyDelayTest", napi_generic_failure);
    return nullptr;
  }
}

napi_value read_proxy_delay_test(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "readProxyDelayTest", status);
      return nullptr;
    }
    if (argc != 1) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "readProxyDelayTest"));
      return nullptr;
    }

    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "readProxyDelayTest"));
      return nullptr;
    }

    AsyncInput input;
    input.op = AsyncOp::PROXY_DELAY_SNAPSHOT;
    CoreErrorData error;
    if (!decode_proxy_delay_job_id(env, argv[0], &input.proxy_delay_job_id, &error, "readProxyDelayTest")) {
      throw_core_error(env, error);
      return nullptr;
    }

    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "readProxyDelayTest", napi_generic_failure);
    return nullptr;
  }
}

napi_value cancel_proxy_delay_test(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "cancelProxyDelayTest", status);
      return nullptr;
    }
    if (argc != 1) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "cancelProxyDelayTest"));
      return nullptr;
    }

    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "cancelProxyDelayTest"));
      return nullptr;
    }

    AsyncInput input;
    input.op = AsyncOp::PROXY_DELAY_CANCEL;
    CoreErrorData error;
    if (!decode_proxy_delay_job_id(env, argv[0], &input.proxy_delay_job_id, &error, "cancelProxyDelayTest")) {
      throw_core_error(env, error);
      return nullptr;
    }

    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "cancelProxyDelayTest", napi_generic_failure);
    return nullptr;
  }
}

} // namespace cmfa::nodeaddon
