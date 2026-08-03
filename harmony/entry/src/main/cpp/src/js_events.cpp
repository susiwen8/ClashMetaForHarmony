#include "cmfa_napi.h"

#include <new>
#include <utility>
#include <vector>

namespace cmfa::nodeaddon {

namespace {

void release_reference_handle(void *handle) {
  auto *subscription = static_cast<Subscription *>(handle);
  if (subscription->addon != nullptr && subscription->callback_ref != nullptr) {
    (void)napi_delete_reference(subscription->addon->env, subscription->callback_ref);
    subscription->callback_ref = nullptr;
  }
}

void abort_subscription_delivery(void *handle) {
  auto *delivery = static_cast<SubscriptionDelivery *>(handle);
  bool expected = false;
  if (delivery->abort_consumed.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
    (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_abort);
  }
}

void release_subscription_delivery(void *handle) {
  auto *delivery = static_cast<SubscriptionDelivery *>(handle);
  if (!delivery->abort_consumed.load(std::memory_order_acquire)) {
    (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_release);
  }
  delete delivery;
}

void deliver_event_to_js(napi_env env, napi_value, void *context, void *data) {
  auto *subscription = static_cast<Subscription *>(context);
  auto *event = static_cast<OwnedCoreEvent *>(data);
  if (env == nullptr) {
    delete event;
    return;
  }
  if (!subscription->active.load(std::memory_order_acquire)) {
    delete event;
    return;
  }

  napi_value callback = nullptr;
  if (napi_get_reference_value(env, subscription->callback_ref, &callback) != napi_ok) {
    delete event;
    return;
  }
  napi_value global = nullptr;
  if (napi_get_global(env, &global) != napi_ok) {
    delete event;
    return;
  }

  CoreErrorData error;
  napi_value js_event = nullptr;
  if (!owned_event_to_js(env, *event, &js_event, &error)) {
    delete event;
    return;
  }

  napi_value argv[1] = {js_event};
  (void)napi_call_function(env, global, callback, 1, argv, nullptr);
  delete event;
}

bool queue_subscription_event(const std::shared_ptr<Subscription> &subscription, const OwnedCoreEvent &event) {
  if (!subscription->active.load(std::memory_order_acquire) || subscription->delivery == nullptr) {
    return false;
  }

  auto *payload = new (std::nothrow) OwnedCoreEvent(event);
  if (payload == nullptr) {
    return false;
  }

  const napi_status status =
      napi_call_threadsafe_function(subscription->delivery->tsfn, payload, napi_tsfn_nonblocking);
  if (status == napi_ok) {
    return true;
  }

  delete payload;
  return false;
}

} // namespace

void emit_log_event(void *context, const cmfa_log_message *message) {
  auto *addon = static_cast<AddonState *>(context);
  if (addon == nullptr || message == nullptr || !addon->owner.can_deliver()) {
    return;
  }

  OwnedCoreEvent event = copy_log_event(*message);
  std::vector<std::shared_ptr<Subscription>> subscriptions;
  {
    std::lock_guard<std::mutex> lock(addon->subscriptions_mutex);
    subscriptions.reserve(addon->subscriptions.size());
    for (const auto &entry : addon->subscriptions) {
      subscriptions.push_back(entry.second);
    }
  }

  for (const auto &subscription : subscriptions) {
    (void)queue_subscription_event(subscription, event);
  }
}

void emit_runtime_event(void *context, const cmfa_runtime_event *message) {
  auto *addon = static_cast<AddonState *>(context);
  if (addon == nullptr || message == nullptr || !addon->owner.can_deliver()) {
    return;
  }

  OwnedCoreEvent event = copy_runtime_event(*message);
  std::vector<std::shared_ptr<Subscription>> subscriptions;
  {
    std::lock_guard<std::mutex> lock(addon->subscriptions_mutex);
    subscriptions.reserve(addon->subscriptions.size());
    for (const auto &entry : addon->subscriptions) {
      subscriptions.push_back(entry.second);
    }
  }

  for (const auto &subscription : subscriptions) {
    (void)queue_subscription_event(subscription, event);
  }
}

napi_value subscribe(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  void *data = nullptr;
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, &data) != napi_ok) {
    throw_napi_failure(env, "subscribe");
    return nullptr;
  }
  if (argc != 1) {
    throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "subscribe"));
    return nullptr;
  }

  auto *addon = static_cast<AddonState *>(data);
  if (addon == nullptr || !addon->owner.can_deliver()) {
    throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "subscribe"));
    return nullptr;
  }

  napi_valuetype callback_type = napi_undefined;
  if (napi_typeof(env, argv[0], &callback_type) != napi_ok) {
    throw_napi_failure(env, "subscribe");
    return nullptr;
  }
  if (callback_type != napi_function) {
    throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "subscribe"));
    return nullptr;
  }

  cmfa_error error{};
  char error_message[128] = {};
  error.message = error_message;
  error.capacity = sizeof(error_message);
  error.length = 0;
  error.code = CMFA_OK;

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  const cmfa_status snapshot_status = cmfa_runtime_state(&snapshot, &error);
  if (snapshot_status != CMFA_OK) {
    throw_core_error(env, make_core_error(snapshot_status, "subscribe"));
    return nullptr;
  }

  CoreErrorData snapshot_error;
  OwnedRuntimeSnapshot initial_snapshot;
  if (!snapshot_to_owned(snapshot, &initial_snapshot, &snapshot_error, "subscribe")) {
    throw_core_error(env, snapshot_error);
    return nullptr;
  }

  auto subscription = std::make_shared<Subscription>();
  subscription->addon = addon;

  if (napi_create_reference(env, argv[0], 1, &subscription->callback_ref) != napi_ok) {
    throw_napi_failure(env, "subscribe");
    return nullptr;
  }

  napi_value resource_name = nullptr;
  if (napi_create_string_utf8(env, "subscribe", NAPI_AUTO_LENGTH, &resource_name) != napi_ok) {
    (void)napi_delete_reference(env, subscription->callback_ref);
    throw_napi_failure(env, "subscribe");
    return nullptr;
  }

  auto *delivery = new (std::nothrow) SubscriptionDelivery{};
  if (delivery == nullptr) {
    (void)napi_delete_reference(env, subscription->callback_ref);
    throw_napi_failure(env, "subscribe");
    return nullptr;
  }
  if (napi_create_threadsafe_function(env,
                                      argv[0],
                                      nullptr,
                                      resource_name,
                                      1,
                                      1,
                                      nullptr,
                                      nullptr,
                                      subscription.get(),
                                      deliver_event_to_js,
                                      &delivery->tsfn) != napi_ok) {
    delete delivery;
    (void)napi_delete_reference(env, subscription->callback_ref);
    throw_napi_failure(env, "subscribe");
    return nullptr;
  }
  subscription->delivery = delivery;

  if (!addon->owner.try_add_reference({subscription.get(), release_reference_handle})) {
    (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_abort);
    delete delivery;
    (void)napi_delete_reference(env, subscription->callback_ref);
    throw_napi_failure(env, "subscribe");
    return nullptr;
  }
  if (!addon->owner.try_add_delivery({delivery, abort_subscription_delivery, release_subscription_delivery})) {
    (void)addon->owner.release_reference(subscription.get());
    throw_napi_failure(env, "subscribe");
    return nullptr;
  }

  uint32_t subscription_id = 0;
  {
    std::lock_guard<std::mutex> lock(addon->subscriptions_mutex);
    subscription_id = addon->next_subscription_id.fetch_add(1, std::memory_order_relaxed);
    if (subscription_id == 0) {
      subscription_id = addon->next_subscription_id.fetch_add(1, std::memory_order_relaxed);
    }
    subscription->id = subscription_id;
    addon->subscriptions.emplace(subscription_id, subscription);
  }

  OwnedCoreEvent initial_event;
  initial_event.kind = OwnedCoreEvent::Kind::RUNTIME;
  initial_event.state = initial_snapshot.state;
  initial_event.message = "";
  (void)queue_subscription_event(subscription, initial_event);

  napi_value result = nullptr;
  if (napi_create_uint32(env, subscription_id, &result) != napi_ok) {
    {
      std::lock_guard<std::mutex> lock(addon->subscriptions_mutex);
      addon->subscriptions.erase(subscription_id);
    }
    subscription->active.store(false, std::memory_order_release);
    (void)addon->owner.release_delivery(delivery, true);
    (void)addon->owner.release_reference(subscription.get());
    throw_napi_failure(env, "subscribe");
    return nullptr;
  }

  return result;
}

napi_value unsubscribe(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  void *data = nullptr;
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, &data) != napi_ok) {
    throw_napi_failure(env, "unsubscribe");
    return nullptr;
  }
  if (argc != 1) {
    throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "unsubscribe"));
    return nullptr;
  }

  uint32_t subscription_id = 0;
  CoreErrorData decode_error;
  if (!decode_subscription_id(env, argv[0], &subscription_id, &decode_error, "unsubscribe")) {
    throw_core_error(env, decode_error);
    return nullptr;
  }

  auto *addon = static_cast<AddonState *>(data);
  std::shared_ptr<Subscription> subscription;
  {
    std::lock_guard<std::mutex> lock(addon->subscriptions_mutex);
    const auto found = addon->subscriptions.find(subscription_id);
    if (found != addon->subscriptions.end()) {
      subscription = found->second;
      addon->subscriptions.erase(found);
    }
  }

  if (subscription != nullptr) {
    subscription->active.store(false, std::memory_order_release);
    (void)addon->owner.release_delivery(subscription->delivery, true);
    (void)addon->owner.release_reference(subscription.get());
  }

  napi_value result = nullptr;
  if (napi_get_undefined(env, &result) != napi_ok) {
    throw_napi_failure(env, "unsubscribe");
    return nullptr;
  }
  return result;
}

} // namespace cmfa::nodeaddon
