#include "cmfa_napi.h"

#include <new>
#include <utility>
#include <vector>

namespace cmfa::nodeaddon {

namespace {

struct SubscriptionTsfnFinalizerState {
  std::shared_ptr<Subscription> subscription;
};

class ScopedInFlightJs final {
public:
  explicit ScopedInFlightJs(Subscription *subscription) : subscription_(subscription), engaged_(false) {}

  void engage() { engaged_ = true; }

  ~ScopedInFlightJs() {
    if (!engaged_ || subscription_ == nullptr) {
      return;
    }
    SubscriptionDelivery *delivery = nullptr;
    bool release_reference = false;
    {
      std::lock_guard<std::mutex> lock(subscription_->mutex);
      if (subscription_->in_flight_js > 0) {
        subscription_->in_flight_js -= 1;
      }
      if (subscription_->in_flight_js == 0) {
        subscription_->callback_thread_id = std::thread::id{};
      }
      if (subscription_->teardown_requested && !subscription_->teardown_started && subscription_->in_flight_js == 0) {
        subscription_->teardown_started = true;
        delivery = subscription_->delivery;
        subscription_->delivery = nullptr;
        release_reference = true;
      }
      subscription_->in_flight_js_cv.notify_all();
    }
    if (subscription_->addon != nullptr && release_reference) {
      if (delivery != nullptr) {
        (void)subscription_->addon->owner.release_delivery(delivery, true);
      }
      (void)subscription_->addon->owner.release_reference(subscription_);
    }
  }

private:
  Subscription *subscription_;
  bool engaged_;
};

bool mark_delivery_teardown(Subscription &subscription,
                            SubscriptionDelivery *delivery,
                            std::unique_lock<std::mutex> &lock) {
  subscription.active = false;
  subscription.teardown_requested = true;
  const bool reentrant_from_callback =
      subscription.callback_thread_id == std::this_thread::get_id() && subscription.in_flight_js != 0;
  if (!reentrant_from_callback) {
    while (subscription.in_flight_js != 0) {
      subscription.in_flight_js_cv.wait(lock);
    }
  }
  if (subscription.delivery == delivery) {
    subscription.delivery = nullptr;
  }
  subscription.teardown_started = true;
  return reentrant_from_callback;
}

void release_reference_handle(void *handle) {
  auto *subscription = static_cast<Subscription *>(handle);
  if (subscription->addon != nullptr && subscription->callback_ref != nullptr) {
    (void)napi_delete_reference(subscription->addon->env, subscription->callback_ref);
    subscription->callback_ref = nullptr;
  }
}

void abort_subscription_delivery(void *handle) {
  auto *delivery = static_cast<SubscriptionDelivery *>(handle);
  if (const std::shared_ptr<Subscription> subscription = delivery->subscription.lock()) {
    std::unique_lock<std::mutex> lock(subscription->mutex);
    (void)mark_delivery_teardown(*subscription, delivery, lock);
  }
  bool expected = false;
  if (delivery->abort_consumed.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
    (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_abort);
  }
}

void release_subscription_delivery(void *handle) {
  auto *delivery = static_cast<SubscriptionDelivery *>(handle);
  if (const std::shared_ptr<Subscription> subscription = delivery->subscription.lock()) {
    std::unique_lock<std::mutex> lock(subscription->mutex);
    (void)mark_delivery_teardown(*subscription, delivery, lock);
  }
  if (!delivery->abort_consumed.load(std::memory_order_acquire)) {
    (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_release);
  }
  delete delivery;
}

void finalize_subscription_tsfn(napi_env, void *finalize_data, void *) {
  delete static_cast<SubscriptionTsfnFinalizerState *>(finalize_data);
}

void deliver_event_to_js(napi_env env, napi_value, void *context, void *data) {
  auto *subscription = static_cast<Subscription *>(context);
  auto *event = static_cast<OwnedCoreEvent *>(data);
  if (env == nullptr) {
    delete event;
    return;
  }

  ScopedInFlightJs in_flight(subscription);
  {
    std::lock_guard<std::mutex> lock(subscription->mutex);
    if (!subscription->active || subscription->callback_ref == nullptr) {
      delete event;
      return;
    }
    subscription->in_flight_js += 1;
    subscription->callback_thread_id = std::this_thread::get_id();
    in_flight.engage();
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
  auto *payload = new (std::nothrow) OwnedCoreEvent(event);
  if (payload == nullptr) {
    return false;
  }

  napi_status status = napi_generic_failure;
  {
    std::lock_guard<std::mutex> lock(subscription->mutex);
    if (!subscription->active || subscription->delivery == nullptr) {
      delete payload;
      return false;
    }
    status = napi_call_threadsafe_function(subscription->delivery->tsfn, payload, napi_tsfn_nonblocking);
  }
  if (status == napi_ok) {
    return true;
  }

  delete payload;
  return false;
}

} // namespace

void emit_log_event(void *context, const cmfa_log_message *message) noexcept {
  try {
    auto *addon = static_cast<AddonState *>(context);
    if (addon == nullptr || message == nullptr || !addon->owner.can_deliver()) {
      return;
    }
    if (log_level_name(message->level) == nullptr) {
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
  } catch (...) {
  }
}

void emit_runtime_event(void *context, const cmfa_runtime_event *message) noexcept {
  try {
    auto *addon = static_cast<AddonState *>(context);
    if (addon == nullptr || message == nullptr || !addon->owner.can_deliver()) {
      return;
    }
    if (runtime_state_name(message->state) == nullptr) {
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
  } catch (...) {
  }
}

napi_value subscribe(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status callback_status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (callback_status != napi_ok) {
      throw_napi_failure(env, "subscribe", callback_status);
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
    const napi_status callback_type_status = napi_typeof(env, argv[0], &callback_type);
    if (callback_type_status != napi_ok) {
      throw_napi_failure(env, "subscribe", callback_type_status);
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

    std::shared_ptr<Subscription> subscription = std::make_shared<Subscription>();
    subscription->addon = addon;

    const napi_status create_reference_status = napi_create_reference(env, argv[0], 1, &subscription->callback_ref);
    if (create_reference_status != napi_ok) {
      throw_napi_failure(env, "subscribe", create_reference_status);
      return nullptr;
    }

    napi_value resource_name = nullptr;
    const napi_status resource_name_status =
        napi_create_string_utf8(env, "subscribe", NAPI_AUTO_LENGTH, &resource_name);
    if (resource_name_status != napi_ok) {
      (void)napi_delete_reference(env, subscription->callback_ref);
      throw_napi_failure(env, "subscribe", resource_name_status);
      return nullptr;
    }

    auto *delivery = new (std::nothrow) SubscriptionDelivery{};
    if (delivery == nullptr) {
      (void)napi_delete_reference(env, subscription->callback_ref);
      throw_napi_failure(env, "subscribe", napi_generic_failure);
      return nullptr;
    }
    delivery->subscription = subscription;

    auto *finalizer_state = new (std::nothrow) SubscriptionTsfnFinalizerState{};
    if (finalizer_state == nullptr) {
      delete delivery;
      (void)napi_delete_reference(env, subscription->callback_ref);
      throw_napi_failure(env, "subscribe", napi_generic_failure);
      return nullptr;
    }
    finalizer_state->subscription = subscription;

    const napi_status tsfn_status = napi_create_threadsafe_function(env,
                                                                    argv[0],
                                                                    nullptr,
                                                                    resource_name,
                                                                    1,
                                                                    1,
                                                                    finalizer_state,
                                                                    finalize_subscription_tsfn,
                                                                    subscription.get(),
                                                                    deliver_event_to_js,
                                                                    &delivery->tsfn);
    if (tsfn_status != napi_ok) {
      delete finalizer_state;
      delete delivery;
      (void)napi_delete_reference(env, subscription->callback_ref);
      throw_napi_failure(env, "subscribe", tsfn_status);
      return nullptr;
    }
    {
      std::lock_guard<std::mutex> lock(subscription->mutex);
      subscription->delivery = delivery;
    }

    if (!addon->owner.try_add_delivery({delivery, abort_subscription_delivery, release_subscription_delivery})) {
      {
        std::lock_guard<std::mutex> lock(subscription->mutex);
        subscription->delivery = nullptr;
      }
      (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_abort);
      (void)napi_delete_reference(env, subscription->callback_ref);
      throw_napi_failure(env, "subscribe", napi_generic_failure);
      return nullptr;
    }
    if (!addon->owner.try_add_reference({subscription.get(), release_reference_handle})) {
      (void)addon->owner.release_delivery(delivery, true);
      (void)napi_delete_reference(env, subscription->callback_ref);
      throw_napi_failure(env, "subscribe", napi_generic_failure);
      return nullptr;
    }

    uint32_t subscription_id = 0;
    bool inserted = false;
    {
      std::lock_guard<std::mutex> lock(addon->subscriptions_mutex);
      uint32_t candidate = addon->next_subscription_id.load(std::memory_order_relaxed);
      for (uint32_t attempts = 0; attempts < UINT32_MAX; attempts += 1) {
        if (candidate == 0) {
          candidate = 1;
        }
        const auto [it, emplaced] = addon->subscriptions.emplace(candidate, subscription);
        if (emplaced) {
          subscription_id = candidate;
          subscription->id = candidate;
          candidate += 1;
          if (candidate == 0) {
            candidate = 1;
          }
          addon->next_subscription_id.store(candidate, std::memory_order_relaxed);
          inserted = true;
          break;
        }
        candidate += 1;
      }
    }
    if (!inserted) {
      {
        std::lock_guard<std::mutex> lock(subscription->mutex);
        subscription->active = false;
      }
      (void)addon->owner.release_delivery(delivery, true);
      (void)addon->owner.release_reference(subscription.get());
      throw_core_error(env, make_core_error(CMFA_BUSY, "subscribe"));
      return nullptr;
    }

    OwnedCoreEvent initial_event;
    initial_event.kind = OwnedCoreEvent::Kind::RUNTIME;
    initial_event.state = initial_snapshot.state;
    initial_event.message = "";
    (void)queue_subscription_event(subscription, initial_event);

    napi_value result = nullptr;
    const napi_status create_id_status = napi_create_uint32(env, subscription_id, &result);
    if (create_id_status != napi_ok) {
      {
        std::lock_guard<std::mutex> lock(addon->subscriptions_mutex);
        addon->subscriptions.erase(subscription_id);
      }
      {
        std::lock_guard<std::mutex> lock(subscription->mutex);
        subscription->active = false;
      }
      (void)addon->owner.release_delivery(delivery, true);
      (void)addon->owner.release_reference(subscription.get());
      throw_napi_failure(env, "subscribe", create_id_status);
      return nullptr;
    }

    return result;
  } catch (...) {
    throw_napi_failure(env, "subscribe", napi_generic_failure);
    return nullptr;
  }
}

napi_value unsubscribe(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status callback_status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (callback_status != napi_ok) {
      throw_napi_failure(env, "unsubscribe", callback_status);
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
      SubscriptionDelivery *delivery = nullptr;
      bool reentrant_from_callback = false;
      {
        std::unique_lock<std::mutex> lock(subscription->mutex);
        subscription->active = false;
        subscription->teardown_requested = true;
        reentrant_from_callback =
            subscription->callback_thread_id == std::this_thread::get_id() && subscription->in_flight_js != 0;
        if (!reentrant_from_callback) {
          while (subscription->in_flight_js != 0) {
            subscription->in_flight_js_cv.wait(lock);
          }
          delivery = subscription->delivery;
          subscription->delivery = nullptr;
          subscription->teardown_started = true;
        }
      }
      if (!reentrant_from_callback) {
        if (delivery != nullptr) {
          (void)addon->owner.release_delivery(delivery, true);
        }
        (void)addon->owner.release_reference(subscription.get());
      }
    }

    napi_value result = nullptr;
    const napi_status undefined_status = napi_get_undefined(env, &result);
    if (undefined_status != napi_ok) {
      throw_napi_failure(env, "unsubscribe", undefined_status);
      return nullptr;
    }
    return result;
  } catch (...) {
    throw_napi_failure(env, "unsubscribe", napi_generic_failure);
    return nullptr;
  }
}

} // namespace cmfa::nodeaddon
