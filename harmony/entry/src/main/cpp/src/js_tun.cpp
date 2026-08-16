#include "cmfa_napi.h"

#include <array>
#include <cstdint>
#include <cstring>

namespace cmfa::nodeaddon {

namespace {

constexpr std::array<const char *, 2> kExactAddresses = {"10.111.222.1/30", "fd00:111:222::1/126"};
constexpr std::array<const char *, 2> kExactRoutes = {"0.0.0.0/0", "::/0"};
constexpr std::array<const char *, 2> kExactDnsServers = {"10.111.222.2", "fd00:111:222::2"};
constexpr uint32_t kExactTunMtu = 1500;
constexpr const char *kSelfPackageName = "com.github.kr328.clash.harmony";
constexpr std::array<const char *, 9> kStartTunOptionKeys = {
    "fd", "vpnId", "sessionId", "configPath", "mixedPort", "platformApiLevel", "processProtected", "captureConfig",
    "dnsServers"};
constexpr std::array<const char *, 9> kCaptureConfigKeys = {
    "addresses",       "routes",          "dnsServers", "mtu", "ipv4",
    "ipv6",            "isBlocking",      "blockedApplications", "trustedApplications"};

template <size_t N>
bool validate_exact_own_keys(napi_env env,
                             napi_value object,
                             const std::array<const char *, N> &expected,
                             CoreErrorData *error,
                             const char *operation) {
  napi_value keys = nullptr;
  napi_status status = napi_get_property_names(env, object, &keys);
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

bool decode_int32_value(napi_env env, napi_value value, int32_t *out, CoreErrorData *error, const char *operation) {
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
  if (raw_value < 0 || raw_value > static_cast<int64_t>(INT32_MAX)) {
    *error = make_core_error(CMFA_OUT_OF_RANGE, operation);
    return false;
  }
  *out = static_cast<int32_t>(raw_value);
  return true;
}

bool decode_uint32_value_local(napi_env env,
                               napi_value value,
                               uint32_t *out,
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
  if (raw_value < 0 || raw_value > static_cast<int64_t>(UINT32_MAX)) {
    *error = make_core_error(CMFA_OUT_OF_RANGE, operation);
    return false;
  }
  *out = static_cast<uint32_t>(raw_value);
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
  if (raw_value < 0) {
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

bool validate_exact_string_array(napi_env env,
                                 napi_value array,
                                 const std::array<const char *, 2> &expected,
                                 CoreErrorData *error,
                                 const char *operation) {
  bool is_array = false;
  napi_status status = napi_is_array(env, array, &is_array);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (!is_array) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  uint32_t length = 0;
  status = napi_get_array_length(env, array, &length);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (length != expected.size()) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  for (uint32_t index = 0; index < length; index += 1) {
    napi_value item = nullptr;
    status = napi_get_element(env, array, index, &item);
    if (status != napi_ok) {
      *error = make_napi_failure(operation, status);
      return false;
    }
    std::string actual;
    if (!decode_utf8_string(env, item, &actual, error, operation, true, CMFA_MAX_PATH_BYTES)) {
      return false;
    }
    if (actual != expected[index]) {
      *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
      return false;
    }
  }
  return true;
}

bool validate_empty_string_array(napi_env env, napi_value array, CoreErrorData *error, const char *operation) {
  bool is_array = false;
  napi_status status = napi_is_array(env, array, &is_array);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (!is_array) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  uint32_t length = 0;
  status = napi_get_array_length(env, array, &length);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (length != 0) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  return true;
}

bool validate_self_package_array(napi_env env, napi_value array, CoreErrorData *error, const char *operation) {
  bool is_array = false;
  napi_status status = napi_is_array(env, array, &is_array);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (!is_array) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  uint32_t length = 0;
  status = napi_get_array_length(env, array, &length);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (length != 1) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  napi_value item = nullptr;
  status = napi_get_element(env, array, 0, &item);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  std::string actual;
  if (!decode_utf8_string(env, item, &actual, error, operation, true, CMFA_MAX_PATH_BYTES)) {
    return false;
  }
  if (actual != kSelfPackageName) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  return true;
}

bool validate_capture_config(napi_env env, napi_value value, CoreErrorData *error) {
  napi_valuetype type = napi_undefined;
  napi_status status = napi_typeof(env, value, &type);
  if (status != napi_ok) {
    *error = make_napi_failure("startTun", status);
    return false;
  }
  if (type != napi_object) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, "startTun");
    return false;
  }
  if (!validate_exact_own_keys(env, value, kCaptureConfigKeys, error, "startTun")) {
    return false;
  }

  napi_value addresses = nullptr;
  napi_value routes = nullptr;
  napi_value dns_servers = nullptr;
  napi_value mtu = nullptr;
  napi_value ipv4 = nullptr;
  napi_value ipv6 = nullptr;
  napi_value is_blocking = nullptr;
  napi_value blocked_applications = nullptr;
  napi_value trusted_applications = nullptr;
  if (!get_named_property_or_error(env, value, "addresses", &addresses, error, "startTun") ||
      !get_named_property_or_error(env, value, "routes", &routes, error, "startTun") ||
      !get_named_property_or_error(env, value, "dnsServers", &dns_servers, error, "startTun") ||
      !get_named_property_or_error(env, value, "mtu", &mtu, error, "startTun") ||
      !get_named_property_or_error(env, value, "ipv4", &ipv4, error, "startTun") ||
      !get_named_property_or_error(env, value, "ipv6", &ipv6, error, "startTun") ||
      !get_named_property_or_error(env, value, "isBlocking", &is_blocking, error, "startTun") ||
      !get_named_property_or_error(env, value, "blockedApplications", &blocked_applications, error, "startTun") ||
      !get_named_property_or_error(env, value, "trustedApplications", &trusted_applications, error, "startTun")) {
    return false;
  }

  if (!validate_exact_string_array(env, addresses, kExactAddresses, error, "startTun") ||
      !validate_exact_string_array(env, routes, kExactRoutes, error, "startTun") ||
      !validate_exact_string_array(env, dns_servers, kExactDnsServers, error, "startTun")) {
    return false;
  }

  uint32_t mtu_value = 0;
  if (!decode_uint32_value_local(env, mtu, &mtu_value, error, "startTun")) {
    return false;
  }
  if (mtu_value != kExactTunMtu) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, "startTun");
    return false;
  }

  bool ipv4_value = false;
  bool ipv6_value = false;
  bool is_blocking_value = false;
  if (!decode_boolean_value(env, ipv4, &ipv4_value, error, "startTun") ||
      !decode_boolean_value(env, ipv6, &ipv6_value, error, "startTun") ||
      !decode_boolean_value(env, is_blocking, &is_blocking_value, error, "startTun")) {
    return false;
  }
  if (!ipv4_value || !ipv6_value || is_blocking_value) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, "startTun");
    return false;
  }

  return validate_self_package_array(env, blocked_applications, error, "startTun") &&
         validate_empty_string_array(env, trusted_applications, error, "startTun");
}

bool decode_tun_start_input(napi_env env, napi_value value, AsyncInput *input, CoreErrorData *error) {
  napi_valuetype type = napi_undefined;
  napi_status status = napi_typeof(env, value, &type);
  if (status != napi_ok) {
    *error = make_napi_failure("startTun", status);
    return false;
  }
  if (type != napi_object) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, "startTun");
    return false;
  }
  if (!validate_exact_own_keys(env, value, kStartTunOptionKeys, error, "startTun")) {
    return false;
  }

  napi_value fd = nullptr;
  napi_value vpn_id = nullptr;
  napi_value session_id = nullptr;
  napi_value config_path = nullptr;
  napi_value mixed_port = nullptr;
  napi_value platform_api_level = nullptr;
  napi_value process_protected = nullptr;
  napi_value capture_config = nullptr;
  napi_value dns_servers = nullptr;
  if (!get_named_property_or_error(env, value, "fd", &fd, error, "startTun") ||
      !get_named_property_or_error(env, value, "vpnId", &vpn_id, error, "startTun") ||
      !get_named_property_or_error(env, value, "sessionId", &session_id, error, "startTun") ||
      !get_named_property_or_error(env, value, "configPath", &config_path, error, "startTun") ||
      !get_named_property_or_error(env, value, "mixedPort", &mixed_port, error, "startTun") ||
      !get_named_property_or_error(env, value, "platformApiLevel", &platform_api_level, error, "startTun") ||
      !get_named_property_or_error(env, value, "processProtected", &process_protected, error, "startTun") ||
      !get_named_property_or_error(env, value, "captureConfig", &capture_config, error, "startTun") ||
      !get_named_property_or_error(env, value, "dnsServers", &dns_servers, error, "startTun")) {
    return false;
  }

  if (!decode_int32_value(env, fd, &input->tun_fd, error, "startTun") || input->tun_fd <= 0) {
    if (error->code.empty()) {
      *error = make_core_error(CMFA_OUT_OF_RANGE, "startTun");
    }
    return false;
  }
  if (!decode_utf8_string(env, vpn_id, &input->tun_vpn_id, error, "startTun", true, CMFA_MAX_PATH_BYTES) ||
      !decode_utf8_string(env, session_id, &input->tun_session_id, error, "startTun", true, CMFA_MAX_TUN_SESSION_ID_BYTES) ||
      !decode_path_argument(env, config_path, &input->tun_config_path, error, "startTun") ||
      !decode_uint32_value_local(env, mixed_port, &input->tun_mixed_port, error, "startTun") ||
      !decode_uint32_value_local(env, platform_api_level, &input->tun_platform_api_level, error, "startTun") ||
      !decode_boolean_value(env, process_protected, &input->tun_process_protected, error, "startTun") ||
      !validate_capture_config(env, capture_config, error) ||
      !validate_exact_string_array(env, dns_servers, kExactDnsServers, error, "startTun")) {
    return false;
  }

  if (input->tun_mixed_port == 0 || input->tun_mixed_port > 65535) {
    *error = make_core_error(CMFA_OUT_OF_RANGE, "startTun");
    return false;
  }
  return true;
}

} // namespace

napi_value start_tun(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "startTun", status);
      return nullptr;
    }
    if (argc != 1) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "startTun"));
      return nullptr;
    }

    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "startTun"));
      return nullptr;
    }

    AsyncInput input;
    input.op = AsyncOp::START_TUN;
    CoreErrorData error;
    if (!decode_tun_start_input(env, argv[0], &input, &error)) {
      throw_core_error(env, error);
      return nullptr;
    }
    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "startTun", napi_generic_failure);
    return nullptr;
  }
}

napi_value stop_tun(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 0;
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, nullptr, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "stopTun", status);
      return nullptr;
    }
    if (argc != 0) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "stopTun"));
      return nullptr;
    }
    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "stopTun"));
      return nullptr;
    }
    AsyncInput input;
    input.op = AsyncOp::STOP_TUN;
    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "stopTun", napi_generic_failure);
    return nullptr;
  }
}

napi_value close_stale_outbound_connections(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "closeStaleOutboundConnections", status);
      return nullptr;
    }
    if (argc != 1) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "closeStaleOutboundConnections"));
      return nullptr;
    }
    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "closeStaleOutboundConnections"));
      return nullptr;
    }

    AsyncInput input;
    input.op = AsyncOp::CLOSE_STALE_OUTBOUND_CONNECTIONS;
    CoreErrorData error;
    if (!decode_utf8_string(env,
                            argv[0],
                            &input.tun_session_id,
                            &error,
                            "closeStaleOutboundConnections",
                            true,
                            CMFA_MAX_TUN_SESSION_ID_BYTES)) {
      throw_core_error(env, error);
      return nullptr;
    }
    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "closeStaleOutboundConnections", napi_generic_failure);
    return nullptr;
  }
}

napi_value tun_snapshot(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 0;
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, nullptr, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "tunSnapshot", status);
      return nullptr;
    }
    if (argc != 0) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "tunSnapshot"));
      return nullptr;
    }
    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "tunSnapshot"));
      return nullptr;
    }
    AsyncInput input;
    input.op = AsyncOp::TUN_SNAPSHOT;
    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "tunSnapshot", napi_generic_failure);
    return nullptr;
  }
}

napi_value read_tun_traces(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "readTunTraces", status);
      return nullptr;
    }
    if (argc != 1) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "readTunTraces"));
      return nullptr;
    }
    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "readTunTraces"));
      return nullptr;
    }
    AsyncInput input;
    input.op = AsyncOp::READ_TUN_TRACES;
    CoreErrorData error;
    if (!decode_uint64_value_local(env, argv[0], &input.tun_after_sequence, &error, "readTunTraces")) {
      throw_core_error(env, error);
      return nullptr;
    }
    return start_async_operation(env, addon, input);
  } catch (...) {
    throw_napi_failure(env, "readTunTraces", napi_generic_failure);
    return nullptr;
  }
}

} // namespace cmfa::nodeaddon
