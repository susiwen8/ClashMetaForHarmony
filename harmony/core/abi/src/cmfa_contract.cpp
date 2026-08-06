#define CMFA_INTERNAL_BACKEND_API 1
#include "cmfa_core.h"

#include <condition_variable>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <mutex>

namespace {

thread_local size_t g_host_callback_depth = 0;
thread_local size_t g_backend_call_depth = 0;

#if defined(CMFA_CONTRACT_TESTING)
std::mutex g_test_hook_mutex;
void (*g_test_hook)(void *context, int point) = nullptr;
void *g_test_hook_context = nullptr;
#endif

struct ContractState {
  std::mutex mutex;
  std::condition_variable cv;
  bool initialized = false;
  bool callbacks_enabled = false;
  bool lifecycle_transition_in_progress = false;
  bool start_in_progress = false;
  bool backend_mutation_in_progress = false;
  size_t in_flight_callbacks = 0;
  size_t in_flight_backend_calls = 0;
  cmfa_host_callbacks host{};
  cmfa_backend_api backend{};
  bool backend_registered = false;
  cmfa_runtime_snapshot snapshot{};
  cmfa_backend_host backend_host{};
};

ContractState g_contract;

bool has_required_size(uint32_t actual, size_t expected) {
  return static_cast<size_t>(actual) >= expected;
}

#if defined(CMFA_CONTRACT_TESTING)
void invoke_test_hook(int point) {
  void (*hook)(void *context, int point) = nullptr;
  void *context = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_test_hook_mutex);
    hook = g_test_hook;
    context = g_test_hook_context;
  }
  if (hook != nullptr) {
    hook(context, point);
  }
}
#else
inline void invoke_test_hook(int) {}
#endif

bool bounded_c_string_length(const char *text, size_t capacity, size_t *length_out) {
  if (text == nullptr) {
    return false;
  }

  for (size_t index = 0; index < capacity; ++index) {
    if (text[index] == '\0') {
      if (length_out != nullptr) {
        *length_out = index;
      }
      return true;
    }
  }

  return false;
}

void write_error_with_length(cmfa_error *error, cmfa_status status, const char *message, size_t message_length) {
  if (error == nullptr) {
    return;
  }

  error->code = status;
  error->length = message_length;
  if (error->message == nullptr || error->capacity == 0) {
    return;
  }

  const size_t writable = error->capacity - 1;
  const size_t copy_length = message_length < writable ? message_length : writable;
  if (copy_length > 0 && message != nullptr) {
    std::memmove(error->message, message, copy_length);
  }
  error->message[copy_length] = '\0';
}

void write_error_literal(cmfa_error *error, cmfa_status status, const char *message) {
  write_error_with_length(error, status, message, message != nullptr ? std::strlen(message) : 0);
}

cmfa_status fail(cmfa_error *error, cmfa_status status, const char *message) {
  write_error_literal(error, status, message);
  return status;
}

void clear_error(cmfa_error *error) { write_error_with_length(error, CMFA_OK, "", 0); }

cmfa_status finalize_backend_error(cmfa_error *error, cmfa_status status, const char *fallback_message) {
  if (error == nullptr) {
    return status;
  }

  size_t backend_length = 0;
  if (error->message != nullptr && error->capacity > 0 &&
      bounded_c_string_length(error->message, error->capacity, &backend_length)) {
    error->code = status;
    error->length = backend_length;
    return status;
  }

  write_error_literal(error, status, fallback_message);
  return status;
}

bool is_valid_runtime_state(cmfa_runtime_state_value state) {
  return state == CMFA_RUNTIME_STOPPED || state == CMFA_RUNTIME_STARTING || state == CMFA_RUNTIME_RUNNING ||
         state == CMFA_RUNTIME_STOPPING || state == CMFA_RUNTIME_ERROR;
}

bool is_valid_utf8_span(const char *text, size_t length) {
  if (text == nullptr) {
    return false;
  }

  const unsigned char *bytes = reinterpret_cast<const unsigned char *>(text);
  size_t index = 0;
  while (index < length) {
    const unsigned char lead = bytes[index];
    if (lead <= 0x7F) {
      index += 1;
      continue;
    }

    size_t needed = 0;
    uint32_t code_point = 0;
    uint32_t min_code_point = 0;
    if (lead >= 0xC2 && lead <= 0xDF) {
      needed = 2;
      code_point = lead & 0x1F;
      min_code_point = 0x80;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
      needed = 3;
      code_point = lead & 0x0F;
      min_code_point = 0x800;
    } else if (lead >= 0xF0 && lead <= 0xF4) {
      needed = 4;
      code_point = lead & 0x07;
      min_code_point = 0x10000;
    } else {
      return false;
    }

    for (size_t offset = 1; offset < needed; ++offset) {
      if (index + offset >= length) {
        return false;
      }
      const unsigned char continuation = bytes[index + offset];
      if ((continuation & 0xC0) != 0x80) {
        return false;
      }
      code_point = (code_point << 6U) | static_cast<uint32_t>(continuation & 0x3F);
    }

    if (code_point < min_code_point || code_point > 0x10FFFF ||
        (code_point >= 0xD800 && code_point <= 0xDFFF)) {
      return false;
    }

    index += needed;
  }

  return true;
}

void zero_text_buffer(char *buffer) {
  if (buffer != nullptr) {
    buffer[0] = '\0';
  }
}

void copy_text_buffer(char *destination, const char *source, size_t length) {
  if (destination == nullptr) {
    return;
  }
  if (source != nullptr && length > 0) {
    std::memcpy(destination, source, length);
  }
  destination[length] = '\0';
}

cmfa_status validate_path_argument(const char *path, size_t *length_out, cmfa_error *error) {
  size_t length = 0;
  if (path == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "path must not be null");
  }
  if (!bounded_c_string_length(path, CMFA_MAX_PATH_BYTES, &length)) {
    return fail(error, CMFA_OUT_OF_RANGE, "path exceeds CMFA_MAX_PATH_BYTES");
  }
  if (length == 0) {
    return fail(error, CMFA_INVALID_ARGUMENT, "path must not be empty");
  }
  if (!is_valid_utf8_span(path, length)) {
    return fail(error, CMFA_INVALID_UTF8, "path must be valid UTF-8");
  }
  if (length_out != nullptr) {
    *length_out = length;
  }
  clear_error(error);
  return CMFA_OK;
}

cmfa_status validate_snapshot_text_buffer(const char *buffer,
                                          cmfa_error *error,
                                          bool allow_empty,
                                          const char *unterminated_message,
                                          const char *empty_message,
                                          const char *invalid_utf8_message) {
  size_t length = 0;
  if (!bounded_c_string_length(buffer, CMFA_MAX_PATH_BYTES, &length)) {
    return fail(error, CMFA_BACKEND_ERROR, unterminated_message);
  }
  if (length == 0) {
    if (allow_empty) {
      clear_error(error);
      return CMFA_OK;
    }
    return fail(error, CMFA_BACKEND_ERROR, empty_message);
  }
  if (!is_valid_utf8_span(buffer, length)) {
    return fail(error, CMFA_BACKEND_ERROR, invalid_utf8_message);
  }
  clear_error(error);
  return CMFA_OK;
}

cmfa_status validate_snapshot_path_buffer(const char *path_buffer, cmfa_error *error, bool allow_empty) {
  return validate_snapshot_text_buffer(path_buffer,
                                       error,
                                       allow_empty,
                                       "snapshot path buffer must be NUL terminated",
                                       "snapshot path must not be empty",
                                       "snapshot path must be valid UTF-8");
}

void store_snapshot_locked(const cmfa_runtime_snapshot &snapshot) {
  g_contract.snapshot.struct_size = sizeof(cmfa_runtime_snapshot);
  g_contract.snapshot.state = snapshot.state;
  g_contract.snapshot.mixed_port = snapshot.mixed_port;
  size_t length = 0;
  if (bounded_c_string_length(snapshot.active_config_path, CMFA_MAX_PATH_BYTES, &length)) {
    copy_text_buffer(g_contract.snapshot.active_config_path, snapshot.active_config_path, length);
  } else {
    zero_text_buffer(g_contract.snapshot.active_config_path);
  }
  if (bounded_c_string_length(snapshot.http_address, CMFA_MAX_PATH_BYTES, &length)) {
    copy_text_buffer(g_contract.snapshot.http_address, snapshot.http_address, length);
  } else {
    zero_text_buffer(g_contract.snapshot.http_address);
  }
  if (bounded_c_string_length(snapshot.socks_address, CMFA_MAX_PATH_BYTES, &length)) {
    copy_text_buffer(g_contract.snapshot.socks_address, snapshot.socks_address, length);
  } else {
    zero_text_buffer(g_contract.snapshot.socks_address);
  }
  if (bounded_c_string_length(snapshot.last_error, CMFA_MAX_PATH_BYTES, &length)) {
    copy_text_buffer(g_contract.snapshot.last_error, snapshot.last_error, length);
  } else {
    zero_text_buffer(g_contract.snapshot.last_error);
  }
}

void reset_snapshot_locked() {
  g_contract.snapshot.struct_size = sizeof(cmfa_runtime_snapshot);
  g_contract.snapshot.state = CMFA_RUNTIME_STOPPED;
  g_contract.snapshot.mixed_port = 0;
  zero_text_buffer(g_contract.snapshot.active_config_path);
  zero_text_buffer(g_contract.snapshot.http_address);
  zero_text_buffer(g_contract.snapshot.socks_address);
  zero_text_buffer(g_contract.snapshot.last_error);
}

void zero_probe_text(char *buffer, size_t capacity) {
  if (buffer == nullptr || capacity == 0) {
    return;
  }
  std::memset(buffer, 0, capacity);
}

void copy_probe_text(char *destination, size_t capacity, const char *source, size_t length) {
  if (destination == nullptr || capacity == 0) {
    return;
  }
  const size_t writable = capacity - 1;
  const size_t copy_length = length < writable ? length : writable;
  zero_probe_text(destination, capacity);
  if (source != nullptr && copy_length > 0) {
    std::memcpy(destination, source, copy_length);
  }
  destination[copy_length] = '\0';
}

void initialize_probe_error(cmfa_probe_error *error) {
  if (error == nullptr) {
    return;
  }
  error->struct_size = sizeof(cmfa_probe_error);
  zero_probe_text(error->code, sizeof(error->code));
  zero_probe_text(error->stage, sizeof(error->stage));
  zero_probe_text(error->detail, sizeof(error->detail));
}

void initialize_probe_tracker(cmfa_probe_tracker_record *tracker) {
  if (tracker == nullptr) {
    return;
  }
  tracker->struct_size = sizeof(cmfa_probe_tracker_record);
  zero_probe_text(tracker->connection_id, sizeof(tracker->connection_id));
  zero_probe_text(tracker->source_address, sizeof(tracker->source_address));
  zero_probe_text(tracker->destination_address, sizeof(tracker->destination_address));
  zero_probe_text(tracker->inbound_type, sizeof(tracker->inbound_type));
  zero_probe_text(tracker->opened_at, sizeof(tracker->opened_at));
}

void initialize_probe_result(cmfa_probe_result *result) {
  if (result == nullptr) {
    return;
  }
  std::memset(result, 0, sizeof(cmfa_probe_result));
  result->struct_size = sizeof(cmfa_probe_result);
  result->protocol = CMFA_PROBE_PROTOCOL_UNSPECIFIED;
  initialize_probe_tracker(&result->tracker);
  initialize_probe_error(&result->error);
}

void write_probe_result_error(cmfa_probe_result *result, const char *code, const char *stage, const char *detail) {
  if (result == nullptr) {
    return;
  }
  const size_t code_length = code != nullptr ? std::strlen(code) : 0;
  const size_t stage_length = stage != nullptr ? std::strlen(stage) : 0;
  const size_t detail_length = detail != nullptr ? std::strlen(detail) : 0;
  copy_probe_text(result->error.code, sizeof(result->error.code), code, code_length);
  copy_probe_text(result->error.stage, sizeof(result->error.stage), stage, stage_length);
  copy_probe_text(result->error.detail, sizeof(result->error.detail), detail, detail_length);
}

cmfa_status validate_utf8_argument(const char *text,
                                   size_t max_length,
                                   const char *null_message,
                                   const char *empty_message,
                                   const char *unterminated_message,
                                   const char *invalid_utf8_message,
                                   bool allow_empty,
                                   cmfa_error *error) {
  size_t length = 0;
  if (text == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, null_message);
  }
  if (!bounded_c_string_length(text, max_length, &length)) {
    return fail(error, CMFA_OUT_OF_RANGE, unterminated_message);
  }
  if (length == 0 && !allow_empty) {
    return fail(error, CMFA_INVALID_ARGUMENT, empty_message);
  }
  if (!is_valid_utf8_span(text, length)) {
    return fail(error, CMFA_INVALID_UTF8, invalid_utf8_message);
  }
  clear_error(error);
  return CMFA_OK;
}

cmfa_status validate_probe_request(const cmfa_probe_request *request, cmfa_error *error) {
  if (request == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "probe request must not be null");
  }
  if (!has_required_size(request->struct_size, sizeof(cmfa_probe_request))) {
    return fail(error, CMFA_INVALID_ARGUMENT, "probe request struct_size is too small");
  }
  if (request->protocol != CMFA_PROBE_PROTOCOL_HTTP_CONNECT && request->protocol != CMFA_PROBE_PROTOCOL_SOCKS5) {
    return fail(error, CMFA_INVALID_ARGUMENT, "probe request protocol is invalid");
  }
  cmfa_status status = validate_utf8_argument(request->probe_run_id,
                                              CMFA_MAX_PROBE_ID_BYTES,
                                              "probe_run_id must not be null",
                                              "probe_run_id must not be empty",
                                              "probe_run_id exceeds CMFA_MAX_PROBE_ID_BYTES",
                                              "probe_run_id must be valid UTF-8",
                                              false,
                                              error);
  if (status != CMFA_OK) {
    return status;
  }
  status = validate_utf8_argument(request->listener_address,
                                  CMFA_MAX_PATH_BYTES,
                                  "listener_address must not be null",
                                  "listener_address must not be empty",
                                  "listener_address exceeds CMFA_MAX_PATH_BYTES",
                                  "listener_address must be valid UTF-8",
                                  false,
                                  error);
  if (status != CMFA_OK) {
    return status;
  }
  status = validate_utf8_argument(request->origin_url,
                                  CMFA_MAX_PATH_BYTES,
                                  "origin_url must not be null",
                                  "origin_url must not be empty",
                                  "origin_url exceeds CMFA_MAX_PATH_BYTES",
                                  "origin_url must be valid UTF-8",
                                  false,
                                  error);
  if (status != CMFA_OK) {
    return status;
  }
  status = validate_utf8_argument(request->ca_pem,
                                  CMFA_MAX_PROBE_PEM_BYTES,
                                  "ca_pem must not be null",
                                  "ca_pem must not be empty",
                                  "ca_pem exceeds CMFA_MAX_PROBE_PEM_BYTES",
                                  "ca_pem must be valid UTF-8",
                                  false,
                                  error);
  if (status != CMFA_OK) {
    return status;
  }
  status = validate_utf8_argument(request->expected_body_sha256,
                                  CMFA_MAX_PROBE_DIGEST_BYTES,
                                  "expected_body_sha256 must not be null",
                                  "expected_body_sha256 must not be empty",
                                  "expected_body_sha256 exceeds CMFA_MAX_PROBE_DIGEST_BYTES",
                                  "expected_body_sha256 must be valid UTF-8",
                                  false,
                                  error);
  return status;
}

cmfa_status validate_snapshot_output(cmfa_runtime_snapshot *snapshot, cmfa_error *error) {
  if (snapshot == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "snapshot must not be null");
  }
  clear_error(error);
  return CMFA_OK;
}

void wait_for_quiescent_locked(std::unique_lock<std::mutex> &lock) {
  const size_t exempt_callbacks = g_host_callback_depth;
  g_contract.cv.wait(lock, [&] {
    return g_contract.in_flight_callbacks <= exempt_callbacks && !g_contract.start_in_progress &&
           g_contract.in_flight_backend_calls == 0;
  });
}

cmfa_status validate_backend_api_complete(const cmfa_backend_api *backend, cmfa_error *error) {
  if (backend == nullptr) {
    clear_error(error);
    return CMFA_OK;
  }
  if (!has_required_size(backend->struct_size, sizeof(cmfa_backend_api))) {
    return fail(error, CMFA_INVALID_ARGUMENT, "backend struct_size is too small");
  }
  if (backend->attach_host == nullptr || backend->core_version == nullptr || backend->validate_config == nullptr ||
      backend->load_config == nullptr || backend->start_local == nullptr || backend->stop == nullptr ||
      backend->runtime_state == nullptr || backend->probe_https == nullptr || backend->shutdown == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "backend lifecycle hooks must all be present");
  }
  clear_error(error);
  return CMFA_OK;
}

cmfa_status begin_backend_call(cmfa_backend_api *backend_out,
                               cmfa_error *error,
                               bool allow_missing_backend = false,
                               bool *borrowed_backend = nullptr) {
  invoke_test_hook(1);
  std::unique_lock<std::mutex> lock(g_contract.mutex);
  g_contract.cv.wait(lock, [] { return !g_contract.backend_mutation_in_progress; });
  if (!g_contract.initialized) {
    return fail(error, CMFA_NOT_INITIALIZED, "cmfa_initialize must succeed first");
  }
  if (g_contract.lifecycle_transition_in_progress) {
    return fail(error, CMFA_BUSY, "runtime lifecycle transition is in progress");
  }
  if (!g_contract.backend_registered) {
    if (allow_missing_backend) {
      if (borrowed_backend != nullptr) {
        *borrowed_backend = false;
      }
      clear_error(error);
      return CMFA_OK;
    }
    return fail(error, CMFA_CORE_UNAVAILABLE, "core backend is unavailable");
  }
  g_contract.in_flight_backend_calls += 1;
  if (borrowed_backend != nullptr) {
    *borrowed_backend = true;
  }
  *backend_out = g_contract.backend;
  clear_error(error);
  return CMFA_OK;
}

void end_backend_call() {
  std::lock_guard<std::mutex> lock(g_contract.mutex);
  if (g_contract.in_flight_backend_calls > 0) {
    g_contract.in_flight_backend_calls -= 1;
  }
  g_contract.cv.notify_all();
}

cmfa_status emit_log_to_host(void *context, const cmfa_log_message *message, cmfa_error *error) {
  cmfa_log_sink_fn sink = nullptr;
  void *sink_context = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    if (!g_contract.initialized || !g_contract.callbacks_enabled || message == nullptr || g_contract.host.log_sink == nullptr) {
      clear_error(error);
      return CMFA_OK;
    }
    sink = g_contract.host.log_sink;
    sink_context = g_contract.host.context;
    g_contract.in_flight_callbacks += 1;
  }

  (void)context;
  g_host_callback_depth += 1;
  sink(sink_context, message);
  g_host_callback_depth -= 1;

  {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    g_contract.in_flight_callbacks -= 1;
    g_contract.cv.notify_all();
  }
  clear_error(error);
  return CMFA_OK;
}

cmfa_status emit_event_to_host(void *context, const cmfa_runtime_event *event, cmfa_error *error) {
  cmfa_runtime_event_sink_fn sink = nullptr;
  void *sink_context = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    if (!g_contract.initialized || !g_contract.callbacks_enabled || event == nullptr || g_contract.host.event_sink == nullptr) {
      clear_error(error);
      return CMFA_OK;
    }
    sink = g_contract.host.event_sink;
    sink_context = g_contract.host.context;
    g_contract.in_flight_callbacks += 1;
  }

  (void)context;
  g_host_callback_depth += 1;
  sink(sink_context, event);
  g_host_callback_depth -= 1;

  {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    g_contract.in_flight_callbacks -= 1;
    g_contract.cv.notify_all();
  }
  clear_error(error);
  return CMFA_OK;
}

} // namespace

 #if defined(CMFA_CONTRACT_TESTING)
extern "C" CMFA_INTERNAL_VISIBILITY void cmfa_internal_set_test_hook(void (*hook)(void *context, int point),
                                                                     void *context) {
  std::lock_guard<std::mutex> lock(g_test_hook_mutex);
  g_test_hook = hook;
  g_test_hook_context = context;
}
#endif

extern "C" CMFA_INTERNAL_VISIBILITY cmfa_status cmfa_internal_register_backend(const cmfa_backend_api *backend,
                                                                               cmfa_error *error) {
  const cmfa_status validation_status = validate_backend_api_complete(backend, error);
  if (validation_status != CMFA_OK) {
    return validation_status;
  }

  cmfa_backend_api candidate{};

  {
    std::unique_lock<std::mutex> lock(g_contract.mutex);
    g_contract.cv.wait(lock, [] {
      return !g_contract.backend_mutation_in_progress && !g_contract.lifecycle_transition_in_progress;
    });
    if (g_contract.initialized) {
      return fail(error, CMFA_INVALID_STATE, "backend mutation is only allowed before initialize or after shutdown");
    }
    g_contract.backend_mutation_in_progress = true;
    wait_for_quiescent_locked(lock);
    if (backend != nullptr) {
      candidate = *backend;
    }
  }

  if (backend == nullptr) {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    g_contract.backend = {};
    g_contract.backend_registered = false;
    g_contract.backend_mutation_in_progress = false;
    g_contract.cv.notify_all();
    clear_error(error);
    return CMFA_OK;
  }

  {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    g_contract.backend = candidate;
    g_contract.backend_registered = true;
    g_contract.backend_mutation_in_progress = false;
    g_contract.cv.notify_all();
  }
  clear_error(error);
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_initialize(const cmfa_host_callbacks *host, cmfa_error *error) {
  if (host == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "host callbacks must not be null");
  }
  if (!has_required_size(host->struct_size, sizeof(cmfa_host_callbacks))) {
    return fail(error, CMFA_INVALID_ARGUMENT, "host callback struct_size is too small");
  }

  cmfa_backend_api backend_copy{};
  cmfa_backend_host backend_host_copy{};
  bool should_attach = false;

  {
    std::unique_lock<std::mutex> lock(g_contract.mutex);
    g_contract.cv.wait(lock, [] { return !g_contract.backend_mutation_in_progress && !g_contract.lifecycle_transition_in_progress; });
    if (g_contract.initialized) {
      return fail(error, CMFA_ALREADY_INITIALIZED, "cmfa_initialize may only be called once before shutdown");
    }

    g_contract.host = *host;
    g_contract.initialized = true;
    g_contract.callbacks_enabled = true;
    g_contract.start_in_progress = false;
    g_contract.backend_host.struct_size = sizeof(cmfa_backend_host);
    g_contract.backend_host.context = nullptr;
    g_contract.backend_host.host_emit_log = &emit_log_to_host;
    g_contract.backend_host.host_emit_event = &emit_event_to_host;
    reset_snapshot_locked();

    if (g_contract.backend_registered) {
      backend_copy = g_contract.backend;
      backend_host_copy = g_contract.backend_host;
      should_attach = true;
      g_contract.lifecycle_transition_in_progress = true;
      g_contract.in_flight_backend_calls += 1;
    }
  }

  if (should_attach) {
    g_backend_call_depth += 1;
    const cmfa_status status = backend_copy.attach_host(backend_copy.context, &backend_host_copy, error);
    g_backend_call_depth -= 1;
    if (status != CMFA_OK) {
      std::lock_guard<std::mutex> lock(g_contract.mutex);
      g_contract.in_flight_backend_calls -= 1;
      g_contract.initialized = false;
      g_contract.callbacks_enabled = false;
      g_contract.start_in_progress = false;
      reset_snapshot_locked();
      g_contract.lifecycle_transition_in_progress = false;
      g_contract.cv.notify_all();
      return finalize_backend_error(error, status, "backend attach_host failed");
    }
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    g_contract.in_flight_backend_calls -= 1;
    g_contract.lifecycle_transition_in_progress = false;
    g_contract.cv.notify_all();
  }

  clear_error(error);
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_core_version(char *out, size_t capacity, cmfa_error *error) {
  if (out == nullptr || capacity == 0) {
    return fail(error, CMFA_INVALID_ARGUMENT, "version output buffer must not be null or empty");
  }

  cmfa_backend_api backend_copy{};
  const cmfa_status borrow_status = begin_backend_call(&backend_copy, error);
  if (borrow_status != CMFA_OK) {
    out[0] = '\0';
    return borrow_status;
  }

  g_backend_call_depth += 1;
  const cmfa_status status = backend_copy.core_version(backend_copy.context, out, capacity, error);
  g_backend_call_depth -= 1;
  end_backend_call();

  if (status != CMFA_OK) {
    out[capacity - 1] = '\0';
    return finalize_backend_error(error, status, "backend core_version failed");
  }

  size_t version_length = 0;
  if (!bounded_c_string_length(out, capacity, &version_length)) {
    out[capacity - 1] = '\0';
    return finalize_backend_error(error, CMFA_BACKEND_ERROR, "backend core_version output must be NUL terminated");
  }

  clear_error(error);
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_validate_config(const char *path, cmfa_error *error) {
  size_t path_length = 0;
  const cmfa_status argument_status = validate_path_argument(path, &path_length, error);
  if (argument_status != CMFA_OK) {
    return argument_status;
  }
  (void)path_length;

  cmfa_backend_api backend_copy{};
  const cmfa_status borrow_status = begin_backend_call(&backend_copy, error);
  if (borrow_status != CMFA_OK) {
    return borrow_status;
  }

  g_backend_call_depth += 1;
  const cmfa_status status = backend_copy.validate_config(backend_copy.context, path, error);
  g_backend_call_depth -= 1;
  end_backend_call();
  if (status != CMFA_OK) {
    return finalize_backend_error(error, status, "backend validate_config failed");
  }
  clear_error(error);
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_load_config(const char *path, cmfa_error *error) {
  size_t path_length = 0;
  const cmfa_status argument_status = validate_path_argument(path, &path_length, error);
  if (argument_status != CMFA_OK) {
    return argument_status;
  }
  (void)path_length;

  cmfa_backend_api backend_copy{};
  const cmfa_status borrow_status = begin_backend_call(&backend_copy, error);
  if (borrow_status != CMFA_OK) {
    return borrow_status;
  }

  g_backend_call_depth += 1;
  const cmfa_status status = backend_copy.load_config(backend_copy.context, path, error);
  g_backend_call_depth -= 1;
  end_backend_call();
  if (status != CMFA_OK) {
    return finalize_backend_error(error, status, "backend load_config failed");
  }
  clear_error(error);
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_start_local(const cmfa_local_options *options,
                                         cmfa_runtime_snapshot *snapshot,
                                         cmfa_error *error) {
  if (options == nullptr || snapshot == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "options and snapshot must not be null");
  }
  if (!has_required_size(options->struct_size, sizeof(cmfa_local_options))) {
    return fail(error, CMFA_INVALID_ARGUMENT, "local options struct_size is too small");
  }

  size_t path_length = 0;
  const cmfa_status path_status = validate_path_argument(options->config_path, &path_length, error);
  if (path_status != CMFA_OK) {
    return path_status;
  }
  if (options->mixed_port == 0) {
    return fail(error, CMFA_INVALID_ARGUMENT, "mixed_port must be greater than zero");
  }
  if (options->mixed_port > 65535U) {
    return fail(error, CMFA_OUT_OF_RANGE, "mixed_port must fit in uint16");
  }

  cmfa_backend_api backend_copy{};
  cmfa_runtime_snapshot working_snapshot{};

  {
    std::unique_lock<std::mutex> lock(g_contract.mutex);
    g_contract.cv.wait(lock, [] { return !g_contract.backend_mutation_in_progress; });
    if (!g_contract.initialized) {
      return fail(error, CMFA_NOT_INITIALIZED, "cmfa_initialize must succeed first");
    }
    if (g_contract.lifecycle_transition_in_progress) {
      return fail(error, CMFA_BUSY, "runtime lifecycle transition is in progress");
    }
    if (g_contract.start_in_progress || g_contract.snapshot.state == CMFA_RUNTIME_STARTING ||
        g_contract.snapshot.state == CMFA_RUNTIME_RUNNING || g_contract.snapshot.state == CMFA_RUNTIME_STOPPING) {
      return fail(error, CMFA_BUSY, "runtime is not ready for another start");
    }
    if (!g_contract.backend_registered) {
      return fail(error, CMFA_CORE_UNAVAILABLE, "core backend is unavailable");
    }

    g_contract.start_in_progress = true;
    g_contract.callbacks_enabled = true;
    g_contract.snapshot.state = CMFA_RUNTIME_STARTING;
    g_contract.snapshot.mixed_port = options->mixed_port;
    copy_text_buffer(g_contract.snapshot.active_config_path, options->config_path, path_length);
    g_contract.in_flight_backend_calls += 1;
    backend_copy = g_contract.backend;
  }

  working_snapshot.struct_size = sizeof(cmfa_runtime_snapshot);
  working_snapshot.state = CMFA_RUNTIME_STARTING;
  working_snapshot.mixed_port = options->mixed_port;
  copy_text_buffer(working_snapshot.active_config_path, options->config_path, path_length);

  g_backend_call_depth += 1;
  const cmfa_status status = backend_copy.start_local(backend_copy.context, options, &working_snapshot, error);
  g_backend_call_depth -= 1;

  std::unique_lock<std::mutex> lock(g_contract.mutex);
  g_contract.in_flight_backend_calls -= 1;
  g_contract.start_in_progress = false;
  g_contract.cv.notify_all();

  if (g_contract.lifecycle_transition_in_progress || !g_contract.initialized) {
    reset_snapshot_locked();
    return finalize_backend_error(error, CMFA_INVALID_STATE, "runtime start was cancelled by lifecycle transition");
  }
  if (status != CMFA_OK) {
    g_contract.snapshot.state = CMFA_RUNTIME_ERROR;
    return finalize_backend_error(error, status, "backend start_local failed");
  }
  if (!is_valid_runtime_state(working_snapshot.state)) {
    g_contract.snapshot.state = CMFA_RUNTIME_ERROR;
    return finalize_backend_error(error, CMFA_BACKEND_ERROR, "backend returned an invalid runtime state");
  }
  const cmfa_status snapshot_path_status = validate_snapshot_path_buffer(working_snapshot.active_config_path, error, false);
  if (snapshot_path_status != CMFA_OK) {
    g_contract.snapshot.state = CMFA_RUNTIME_ERROR;
    return snapshot_path_status;
  }
  const bool require_addresses = working_snapshot.state == CMFA_RUNTIME_RUNNING;
  const cmfa_status http_status = validate_snapshot_text_buffer(working_snapshot.http_address,
                                                                error,
                                                                !require_addresses,
                                                                "snapshot HTTP address must be NUL terminated",
                                                                "snapshot HTTP address must not be empty",
                                                                "snapshot HTTP address must be valid UTF-8");
  if (http_status != CMFA_OK) {
    g_contract.snapshot.state = CMFA_RUNTIME_ERROR;
    return http_status;
  }
  const cmfa_status socks_status = validate_snapshot_text_buffer(working_snapshot.socks_address,
                                                                 error,
                                                                 !require_addresses,
                                                                 "snapshot SOCKS address must be NUL terminated",
                                                                 "snapshot SOCKS address must not be empty",
                                                                 "snapshot SOCKS address must be valid UTF-8");
  if (socks_status != CMFA_OK) {
    g_contract.snapshot.state = CMFA_RUNTIME_ERROR;
    return socks_status;
  }
  const cmfa_status last_error_status = validate_snapshot_text_buffer(working_snapshot.last_error,
                                                                      error,
                                                                      true,
                                                                      "snapshot last_error must be NUL terminated",
                                                                      "snapshot last_error must not be empty",
                                                                      "snapshot last_error must be valid UTF-8");
  if (last_error_status != CMFA_OK) {
    g_contract.snapshot.state = CMFA_RUNTIME_ERROR;
    return last_error_status;
  }

  store_snapshot_locked(working_snapshot);
  *snapshot = g_contract.snapshot;
  clear_error(error);
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_stop(cmfa_error *error) {
  if (g_host_callback_depth > 0 || g_backend_call_depth > 0) {
    return fail(error, CMFA_INVALID_STATE, "lifecycle APIs cannot be re-entered from host callbacks or backend calls");
  }

  cmfa_backend_api backend_copy{};
  bool should_call_backend = false;
  cmfa_runtime_snapshot backend_snapshot{};
  auto finalize_stop_without_snapshot_mutation = [&] {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    g_contract.callbacks_enabled = false;
    g_contract.lifecycle_transition_in_progress = false;
    g_contract.cv.notify_all();
  };

  {
    std::unique_lock<std::mutex> lock(g_contract.mutex);
    if (!g_contract.initialized) {
      return fail(error, CMFA_NOT_INITIALIZED, "cmfa_initialize must succeed first");
    }
    g_contract.cv.wait(lock, [] { return !g_contract.backend_mutation_in_progress && !g_contract.lifecycle_transition_in_progress; });
    g_contract.lifecycle_transition_in_progress = true;
    wait_for_quiescent_locked(lock);
    if (!g_contract.initialized) {
      g_contract.lifecycle_transition_in_progress = false;
      g_contract.cv.notify_all();
      return fail(error, CMFA_NOT_INITIALIZED, "cmfa_initialize must succeed first");
    }
    should_call_backend = g_contract.backend_registered && g_contract.snapshot.state != CMFA_RUNTIME_STOPPED;
    if (should_call_backend) {
      g_contract.in_flight_backend_calls += 1;
      backend_copy = g_contract.backend;
    }
  }

  if (should_call_backend) {
    g_backend_call_depth += 1;
    const cmfa_status status = backend_copy.stop(backend_copy.context, error);
    g_backend_call_depth -= 1;
    {
      std::lock_guard<std::mutex> lock(g_contract.mutex);
      g_contract.in_flight_backend_calls -= 1;
      g_contract.cv.notify_all();
      if (status != CMFA_OK) {
        g_contract.snapshot.state = CMFA_RUNTIME_ERROR;
        g_contract.callbacks_enabled = false;
        g_contract.lifecycle_transition_in_progress = false;
        g_contract.cv.notify_all();
      }
    }
    if (status != CMFA_OK) {
      return finalize_backend_error(error, status, "backend stop failed");
    }

    backend_snapshot.struct_size = sizeof(cmfa_runtime_snapshot);
    g_backend_call_depth += 1;
    const cmfa_status snapshot_status = backend_copy.runtime_state(backend_copy.context, &backend_snapshot, error);
    g_backend_call_depth -= 1;
    if (snapshot_status != CMFA_OK) {
      finalize_stop_without_snapshot_mutation();
      return finalize_backend_error(error, snapshot_status, "backend runtime_state after stop failed");
    }
    if (!is_valid_runtime_state(backend_snapshot.state)) {
      finalize_stop_without_snapshot_mutation();
      return finalize_backend_error(error, CMFA_BACKEND_ERROR, "backend returned an invalid runtime state after stop");
    }
    const cmfa_status path_status =
        validate_snapshot_path_buffer(backend_snapshot.active_config_path, error,
                                      backend_snapshot.state == CMFA_RUNTIME_STOPPED);
    if (path_status != CMFA_OK) {
      finalize_stop_without_snapshot_mutation();
      return path_status;
    }
    const bool require_addresses = backend_snapshot.state == CMFA_RUNTIME_RUNNING;
    const cmfa_status http_status = validate_snapshot_text_buffer(backend_snapshot.http_address,
                                                                  error,
                                                                  !require_addresses,
                                                                  "snapshot HTTP address must be NUL terminated",
                                                                  "snapshot HTTP address must not be empty",
                                                                  "snapshot HTTP address must be valid UTF-8");
    if (http_status != CMFA_OK) {
      finalize_stop_without_snapshot_mutation();
      return http_status;
    }
    const cmfa_status socks_status = validate_snapshot_text_buffer(backend_snapshot.socks_address,
                                                                   error,
                                                                   !require_addresses,
                                                                   "snapshot SOCKS address must be NUL terminated",
                                                                   "snapshot SOCKS address must not be empty",
                                                                   "snapshot SOCKS address must be valid UTF-8");
    if (socks_status != CMFA_OK) {
      finalize_stop_without_snapshot_mutation();
      return socks_status;
    }
    const cmfa_status last_error_status = validate_snapshot_text_buffer(backend_snapshot.last_error,
                                                                        error,
                                                                        true,
                                                                        "snapshot last_error must be NUL terminated",
                                                                        "snapshot last_error must not be empty",
                                                                        "snapshot last_error must be valid UTF-8");
    if (last_error_status != CMFA_OK) {
      finalize_stop_without_snapshot_mutation();
      return last_error_status;
    }
  }

  {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    if (should_call_backend) {
      store_snapshot_locked(backend_snapshot);
    } else {
      reset_snapshot_locked();
    }
    g_contract.callbacks_enabled = false;
    g_contract.lifecycle_transition_in_progress = false;
    g_contract.cv.notify_all();
  }
  clear_error(error);
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_runtime_state(cmfa_runtime_snapshot *snapshot, cmfa_error *error) {
  const cmfa_status output_status = validate_snapshot_output(snapshot, error);
  if (output_status != CMFA_OK) {
    return output_status;
  }

  cmfa_backend_api backend_copy{};
  bool borrowed_backend = false;
  const cmfa_status borrow_status = begin_backend_call(&backend_copy, error, true, &borrowed_backend);
  if (borrow_status != CMFA_OK) {
    return borrow_status;
  }
  if (!borrowed_backend) {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    *snapshot = g_contract.snapshot;
    clear_error(error);
    return CMFA_OK;
  }

  cmfa_runtime_snapshot backend_snapshot{};
  backend_snapshot.struct_size = sizeof(cmfa_runtime_snapshot);
  g_backend_call_depth += 1;
  const cmfa_status status = backend_copy.runtime_state(backend_copy.context, &backend_snapshot, error);
  g_backend_call_depth -= 1;
  end_backend_call();
  if (status != CMFA_OK) {
    return finalize_backend_error(error, status, "backend runtime_state failed");
  }
  if (!is_valid_runtime_state(backend_snapshot.state)) {
    return finalize_backend_error(error, CMFA_BACKEND_ERROR, "backend returned an invalid runtime state");
  }
  const cmfa_status path_status =
      validate_snapshot_path_buffer(backend_snapshot.active_config_path, error,
                                    backend_snapshot.state == CMFA_RUNTIME_STOPPED);
  if (path_status != CMFA_OK) {
    return path_status;
  }
  const bool require_addresses = backend_snapshot.state == CMFA_RUNTIME_RUNNING;
  const cmfa_status http_status = validate_snapshot_text_buffer(backend_snapshot.http_address,
                                                                error,
                                                                !require_addresses,
                                                                "snapshot HTTP address must be NUL terminated",
                                                                "snapshot HTTP address must not be empty",
                                                                "snapshot HTTP address must be valid UTF-8");
  if (http_status != CMFA_OK) {
    return http_status;
  }
  const cmfa_status socks_status = validate_snapshot_text_buffer(backend_snapshot.socks_address,
                                                                 error,
                                                                 !require_addresses,
                                                                 "snapshot SOCKS address must be NUL terminated",
                                                                 "snapshot SOCKS address must not be empty",
                                                                 "snapshot SOCKS address must be valid UTF-8");
  if (socks_status != CMFA_OK) {
    return socks_status;
  }
  const cmfa_status last_error_status = validate_snapshot_text_buffer(backend_snapshot.last_error,
                                                                      error,
                                                                      true,
                                                                      "snapshot last_error must be NUL terminated",
                                                                      "snapshot last_error must not be empty",
                                                                      "snapshot last_error must be valid UTF-8");
  if (last_error_status != CMFA_OK) {
    return last_error_status;
  }

  invoke_test_hook(2);

  {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    if (!g_contract.initialized) {
      return fail(error, CMFA_NOT_INITIALIZED, "cmfa_initialize must succeed first");
    }
    if (g_contract.lifecycle_transition_in_progress) {
      return fail(error, CMFA_BUSY, "runtime lifecycle transition is in progress");
    }
    store_snapshot_locked(backend_snapshot);
    *snapshot = g_contract.snapshot;
  }
  clear_error(error);
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_probe_https(const cmfa_probe_request *request,
                                        cmfa_probe_result **result,
                                        cmfa_error *error) {
  if (result == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "probe result output must not be null");
  }
  *result = nullptr;

  cmfa_probe_result *allocated = static_cast<cmfa_probe_result *>(std::malloc(sizeof(cmfa_probe_result)));
  if (allocated == nullptr) {
    return fail(error, CMFA_BACKEND_ERROR, "failed to allocate probe result");
  }
  initialize_probe_result(allocated);
  *result = allocated;

  const cmfa_status request_status = validate_probe_request(request, error);
  if (request_status != CMFA_OK) {
    write_probe_result_error(allocated, "INVALID_ARGUMENT", "request", error != nullptr && error->message != nullptr
                                                                      ? error->message
                                                                      : "probe request validation failed");
    return request_status;
  }
  allocated->protocol = request->protocol;

  cmfa_backend_api backend_copy{};
  const cmfa_status borrow_status = begin_backend_call(&backend_copy, error);
  if (borrow_status != CMFA_OK) {
    write_probe_result_error(allocated,
                             borrow_status == CMFA_CORE_UNAVAILABLE ? "CORE_UNAVAILABLE" : "INVALID_STATE",
                             "backend",
                             error != nullptr && error->message != nullptr ? error->message : "probe backend unavailable");
    return borrow_status;
  }

  g_backend_call_depth += 1;
  const cmfa_status status = backend_copy.probe_https(backend_copy.context, request, allocated, error);
  g_backend_call_depth -= 1;
  end_backend_call();

  if (status != CMFA_OK) {
    if (allocated->error.code[0] == '\0') {
      write_probe_result_error(allocated,
                               status == CMFA_BUSY   ? "BUSY"
                               : status == CMFA_OUT_OF_RANGE ? "OUT_OF_RANGE"
                                                             : "BACKEND_ERROR",
                               "backend",
                               error != nullptr && error->message != nullptr ? error->message : "probe backend failed");
    }
    return finalize_backend_error(error, status, "backend probe_https failed");
  }

  clear_error(error);
  return CMFA_OK;
}

extern "C" void cmfa_probe_result_free(cmfa_probe_result *result) {
  std::free(result);
}

extern "C" cmfa_status cmfa_shutdown(cmfa_error *error) {
  if (g_host_callback_depth > 0 || g_backend_call_depth > 0) {
    return fail(error, CMFA_INVALID_STATE, "lifecycle APIs cannot be re-entered from host callbacks or backend calls");
  }

  cmfa_backend_api backend_copy{};
  bool should_call_backend = false;

  {
    std::unique_lock<std::mutex> lock(g_contract.mutex);
    if (!g_contract.initialized) {
      clear_error(error);
      return CMFA_OK;
    }
    g_contract.cv.wait(lock, [] { return !g_contract.backend_mutation_in_progress && !g_contract.lifecycle_transition_in_progress; });
    g_contract.lifecycle_transition_in_progress = true;
    g_contract.callbacks_enabled = false;
    wait_for_quiescent_locked(lock);
    if (!g_contract.initialized) {
      g_contract.lifecycle_transition_in_progress = false;
      g_contract.cv.notify_all();
      clear_error(error);
      return CMFA_OK;
    }
    should_call_backend = g_contract.backend_registered;
    if (should_call_backend) {
      g_contract.in_flight_backend_calls += 1;
      backend_copy = g_contract.backend;
    }
  }

  if (should_call_backend) {
    g_backend_call_depth += 1;
    const cmfa_status status = backend_copy.shutdown(backend_copy.context, error);
    g_backend_call_depth -= 1;
    {
      std::lock_guard<std::mutex> lock(g_contract.mutex);
      g_contract.in_flight_backend_calls -= 1;
      g_contract.cv.notify_all();
      if (status != CMFA_OK) {
        g_contract.lifecycle_transition_in_progress = false;
        g_contract.cv.notify_all();
      }
    }
    if (status != CMFA_OK) {
      return finalize_backend_error(error, status, "backend shutdown failed");
    }
  }

  {
    std::lock_guard<std::mutex> lock(g_contract.mutex);
    g_contract.initialized = false;
    g_contract.callbacks_enabled = false;
    g_contract.start_in_progress = false;
    g_contract.host = {};
    reset_snapshot_locked();
    g_contract.lifecycle_transition_in_progress = false;
    g_contract.cv.notify_all();
  }
  clear_error(error);
  return CMFA_OK;
}
