#include "cmfa_napi.h"

#include <array>
#include <new>
#include <utility>

namespace cmfa::nodeaddon {

namespace {

struct AsyncCompletionPayload {
  AsyncPromiseJob *job = nullptr;
  AsyncResult result;
};

cmfa::napi::ReleaseResult finish_async(AddonState *addon, AsyncThreadHandle *handle) {
  if (addon == nullptr || handle == nullptr) {
    return cmfa::napi::ReleaseResult::NOT_REGISTERED;
  }
  return addon->owner.finish_async(handle);
}

cmfa::napi::ReleaseResult release_delivery(AddonState *addon, AsyncDelivery *delivery, bool abort) {
  if (addon == nullptr || delivery == nullptr) {
    return cmfa::napi::ReleaseResult::NOT_REGISTERED;
  }
  return addon->owner.release_delivery(delivery, abort);
}

void request_cancel_async(void *handle) {
  auto *async_handle = static_cast<AsyncThreadHandle *>(handle);
  async_handle->cancel_requested.store(true, std::memory_order_relaxed);
}

void join_async(void *handle) {
  auto *async_handle = static_cast<AsyncThreadHandle *>(handle);
  if (async_handle->worker.joinable()) {
    async_handle->worker.join();
  }
}

void release_async(void *handle) {
  auto *async_handle = static_cast<AsyncThreadHandle *>(handle);
  if (async_handle->worker.joinable()) {
    async_handle->worker.join();
  }
  delete async_handle;
}

void abort_delivery(void *handle) {
  auto *delivery = static_cast<AsyncDelivery *>(handle);
  bool expected = false;
  if (delivery->abort_consumed.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
    (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_abort);
  }
}

void release_delivery_handle(void *handle) {
  auto *delivery = static_cast<AsyncDelivery *>(handle);
  if (!delivery->abort_consumed.load(std::memory_order_acquire)) {
    (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_release);
  }
  delete delivery;
}

void tsfn_finalize_async(napi_env, void *finalize_data, void *) {
  delete static_cast<AsyncPromiseJob *>(finalize_data);
}

bool build_async_result_value(napi_env env, const AsyncResult &result, napi_value *value) {
  CoreErrorData error;
  switch (result.op) {
    case AsyncOp::CORE_VERSION:
      if (napi_create_string_utf8(env, result.string_value.c_str(), result.string_value.size(), value) != napi_ok) {
        return false;
      }
      return true;
    case AsyncOp::VALIDATE_CONFIGURATION:
    case AsyncOp::LOAD_CONFIGURATION:
      return napi_get_undefined(env, value) == napi_ok;
    case AsyncOp::START_LOCAL:
    case AsyncOp::STOP_RUNTIME:
      return owned_snapshot_to_js(env, result.snapshot, value, &error);
    default:
      return false;
  }
}

AsyncResult run_async_operation(const AsyncInput &input, const std::atomic<bool> &cancel_requested) {
  AsyncResult result;
  result.op = input.op;

  if (cancel_requested.load(std::memory_order_relaxed)) {
    result.error = make_napi_failure(async_operation_name(input.op));
    return result;
  }

  cmfa_error error{};
  std::array<char, 256> error_message{};
  error.message = error_message.data();
  error.capacity = error_message.size();
  error.length = 0;
  error.code = CMFA_OK;

  switch (input.op) {
    case AsyncOp::CORE_VERSION: {
      std::array<char, 256> version{};
      const cmfa_status status = cmfa_core_version(version.data(), version.size(), &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      if (version[0] == '\0') {
        result.error = make_core_error(CMFA_BACKEND_ERROR, async_operation_name(input.op));
        return result;
      }
      result.ok = true;
      result.string_value = version.data();
      return result;
    }
    case AsyncOp::VALIDATE_CONFIGURATION: {
      const cmfa_status status = cmfa_validate_config(input.path.c_str(), &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      result.ok = true;
      return result;
    }
    case AsyncOp::LOAD_CONFIGURATION: {
      const cmfa_status status = cmfa_load_config(input.path.c_str(), &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      result.ok = true;
      return result;
    }
    case AsyncOp::START_LOCAL: {
      cmfa_local_options options{};
      options.struct_size = sizeof(options);
      options.config_path = input.local_options.config_path.c_str();
      options.mixed_port = input.local_options.mixed_port;

      cmfa_runtime_snapshot snapshot{};
      snapshot.struct_size = sizeof(snapshot);
      const cmfa_status status = cmfa_start_local(&options, &snapshot, &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      CoreErrorData snapshot_error;
      if (!snapshot_to_owned(snapshot, &result.snapshot, &snapshot_error, async_operation_name(input.op))) {
        result.error = snapshot_error;
        return result;
      }
      result.ok = true;
      return result;
    }
    case AsyncOp::STOP_RUNTIME: {
      const cmfa_status stop_status = cmfa_stop(&error);
      if (stop_status != CMFA_OK) {
        result.error = make_core_error(stop_status, async_operation_name(input.op));
        return result;
      }
      cmfa_runtime_snapshot snapshot{};
      snapshot.struct_size = sizeof(snapshot);
      const cmfa_status snapshot_status = cmfa_runtime_state(&snapshot, &error);
      if (snapshot_status != CMFA_OK) {
        result.error = make_core_error(snapshot_status, async_operation_name(input.op));
        return result;
      }
      CoreErrorData snapshot_error;
      if (!snapshot_to_owned(snapshot, &result.snapshot, &snapshot_error, async_operation_name(input.op))) {
        result.error = snapshot_error;
        return result;
      }
      result.ok = true;
      return result;
    }
    default:
      result.error = make_napi_failure("asyncOperation");
      return result;
  }
}

void complete_promise(napi_env env, napi_value, void *, void *data) {
  auto *payload = static_cast<AsyncCompletionPayload *>(data);
  if (env == nullptr) {
    delete payload;
    return;
  }

  AsyncPromiseJob *job = payload->job;
  AddonState *addon = job->addon;

  if (payload->result.ok) {
    napi_value resolution = nullptr;
    if (build_async_result_value(env, payload->result, &resolution)) {
      (void)napi_resolve_deferred(env, job->deferred, resolution);
    } else {
      reject_deferred_with_napi_failure(env, job->deferred, async_operation_name(job->input.op));
    }
  } else {
    reject_deferred_with_core_error(env, job->deferred, payload->result.error);
  }

  (void)finish_async(addon, job->async_handle);
  (void)release_delivery(addon, job->delivery, false);
  delete payload;
}

void async_worker_main(AsyncPromiseJob *job) {
  AsyncResult result = run_async_operation(job->input, job->async_handle->cancel_requested);
  auto *payload = new (std::nothrow) AsyncCompletionPayload{};
  if (payload == nullptr) {
    return;
  }
  payload->job = job;
  payload->result = std::move(result);

  const napi_status status =
      napi_call_threadsafe_function(job->delivery->tsfn, payload, napi_tsfn_nonblocking);
  if (status != napi_ok && status != napi_closing) {
    delete payload;
  }
}

napi_value create_async_operation(napi_env env,
                                  napi_callback_info info,
                                  AsyncOp op,
                                  bool (*decode)(napi_env, napi_callback_info, AsyncInput *, CoreErrorData *)) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  void *data = nullptr;
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, &data) != napi_ok) {
    throw_napi_failure(env, async_operation_name(op));
    return nullptr;
  }

  auto *addon = static_cast<AddonState *>(data);
  if (addon == nullptr || !addon->owner.can_deliver()) {
    throw_core_error(env, make_core_error(CMFA_INVALID_STATE, async_operation_name(op)));
    return nullptr;
  }

  AsyncInput input;
  input.op = op;
  CoreErrorData decode_error;
  if (!decode(env, info, &input, &decode_error)) {
    throw_core_error(env, decode_error);
    return nullptr;
  }

  napi_deferred deferred = nullptr;
  napi_value promise = nullptr;
  if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
    throw_napi_failure(env, async_operation_name(op));
    return nullptr;
  }

  auto *job = new (std::nothrow) AsyncPromiseJob{};
  if (job == nullptr) {
    reject_deferred_with_napi_failure(env, deferred, async_operation_name(op));
    return promise;
  }
  job->addon = addon;
  job->deferred = deferred;
  job->input = input;

  napi_value async_name = nullptr;
  if (napi_create_string_utf8(env, async_operation_name(op), NAPI_AUTO_LENGTH, &async_name) != napi_ok) {
    delete job;
    reject_deferred_with_napi_failure(env, deferred, async_operation_name(op));
    return promise;
  }

  auto *delivery = new (std::nothrow) AsyncDelivery{};
  if (delivery == nullptr) {
    delete job;
    reject_deferred_with_napi_failure(env, deferred, async_operation_name(op));
    return promise;
  }
  if (napi_create_threadsafe_function(env,
                                      nullptr,
                                      nullptr,
                                      async_name,
                                      1,
                                      1,
                                      job,
                                      tsfn_finalize_async,
                                      nullptr,
                                      complete_promise,
                                      &delivery->tsfn) != napi_ok) {
    delete delivery;
    delete job;
    reject_deferred_with_napi_failure(env, deferred, async_operation_name(op));
    return promise;
  }
  job->delivery = delivery;

  if (!addon->owner.try_add_delivery({delivery, abort_delivery, release_delivery_handle})) {
    (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_abort);
    delete delivery;
    reject_deferred_with_napi_failure(env, deferred, async_operation_name(op));
    return promise;
  }

  auto *async_handle = new (std::nothrow) AsyncThreadHandle{};
  if (async_handle == nullptr) {
    (void)release_delivery(addon, delivery, true);
    reject_deferred_with_napi_failure(env, deferred, async_operation_name(op));
    return promise;
  }
  if (!addon->owner.try_add_async({async_handle, request_cancel_async, join_async, release_async})) {
    delete async_handle;
    (void)release_delivery(addon, delivery, true);
    reject_deferred_with_napi_failure(env, deferred, async_operation_name(op));
    return promise;
  }
  job->async_handle = async_handle;

  try {
    async_handle->worker = std::thread([job] { async_worker_main(job); });
  } catch (...) {
    (void)finish_async(addon, async_handle);
    (void)release_delivery(addon, delivery, true);
    reject_deferred_with_napi_failure(env, deferred, async_operation_name(op));
  }

  return promise;
}

bool decode_no_arguments(napi_env env, napi_callback_info info, AsyncInput *out, CoreErrorData *error) {
  size_t argc = 0;
  void *data = nullptr;
  if (napi_get_cb_info(env, info, &argc, nullptr, nullptr, &data) != napi_ok) {
    *error = make_napi_failure(async_operation_name(out->op));
    return false;
  }
  if (argc != 0) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, async_operation_name(out->op));
    return false;
  }
  return true;
}

bool decode_path_argument_for_async(napi_env env, napi_callback_info info, AsyncInput *out, CoreErrorData *error) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) {
    *error = make_napi_failure(async_operation_name(out->op));
    return false;
  }
  if (argc != 1) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, async_operation_name(out->op));
    return false;
  }
  return decode_path_argument(env, argv[0], &out->path, error, async_operation_name(out->op));
}

bool decode_local_options_for_async(napi_env env, napi_callback_info info, AsyncInput *out, CoreErrorData *error) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) {
    *error = make_napi_failure(async_operation_name(out->op));
    return false;
  }
  if (argc != 1) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, async_operation_name(out->op));
    return false;
  }
  return decode_local_options(env, argv[0], &out->local_options, error);
}

} // namespace

napi_value core_version(napi_env env, napi_callback_info info) {
  return create_async_operation(env, info, AsyncOp::CORE_VERSION, decode_no_arguments);
}

napi_value validate_configuration(napi_env env, napi_callback_info info) {
  return create_async_operation(env, info, AsyncOp::VALIDATE_CONFIGURATION, decode_path_argument_for_async);
}

napi_value load_configuration(napi_env env, napi_callback_info info) {
  return create_async_operation(env, info, AsyncOp::LOAD_CONFIGURATION, decode_path_argument_for_async);
}

napi_value start_local(napi_env env, napi_callback_info info) {
  return create_async_operation(env, info, AsyncOp::START_LOCAL, decode_local_options_for_async);
}

napi_value stop_runtime(napi_env env, napi_callback_info info) {
  return create_async_operation(env, info, AsyncOp::STOP_RUNTIME, decode_no_arguments);
}

} // namespace cmfa::nodeaddon
