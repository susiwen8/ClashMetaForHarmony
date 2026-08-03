#include "napi_environment.h"

#include <array>
#include <utility>
#include <vector>

namespace cmfa::napi {

namespace {

struct LocalErrorBuffer {
  std::array<char, 128> storage{};
  cmfa_error error{};

  LocalErrorBuffer() {
    error.code = CMFA_OK;
    error.message = storage.data();
    error.capacity = storage.size();
    error.length = 0;
  }
};

cmfa_status invoke_lifecycle(cmfa_status (*operation)(void *, cmfa_error *), void *context) {
  if (operation == nullptr) {
    return CMFA_OK;
  }
  LocalErrorBuffer error;
  return operation(context, &error.error);
}

bool valid_registration(const AsyncWorkRegistration &registration) {
  return registration.handle != nullptr && registration.request_cancel != nullptr &&
         registration.join != nullptr && registration.release != nullptr;
}

bool valid_registration(const DeliveryRegistration &registration) {
  return registration.handle != nullptr && registration.abort != nullptr && registration.release != nullptr;
}

bool valid_registration(const ReferenceRegistration &registration) {
  return registration.handle != nullptr && registration.release != nullptr;
}

} // namespace

NapiEnvironmentOwner::NapiEnvironmentOwner(LifecycleOperations operations)
    : lifecycle_(operations),
      state_(State::CREATED),
      delivery_enabled_(false),
      cached_shutdown_status_(CMFA_OK),
      cached_unregister_status_(CMFA_OK) {}

NapiEnvironmentOwner::~NapiEnvironmentOwner() {
  (void)cleanup();
}

bool NapiEnvironmentOwner::activate() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (state_ != State::CREATED) {
    return false;
  }
  state_ = State::ACTIVE;
  delivery_enabled_ = true;
  return true;
}

bool NapiEnvironmentOwner::can_deliver() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return delivery_enabled_;
}

bool NapiEnvironmentOwner::try_add_async(AsyncWorkRegistration registration) {
  if (!valid_registration(registration)) {
    return false;
  }

  std::lock_guard<std::mutex> lock(mutex_);
  if (state_ != State::CREATED && state_ != State::ACTIVE) {
    return false;
  }
  return async_work_.emplace(registration.handle, registration).second;
}

ReleaseResult NapiEnvironmentOwner::finish_async(void *handle) {
  AsyncWorkRegistration registration{};
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (claimed_async_.find(handle) != claimed_async_.end()) {
      return ReleaseResult::CLAIMED_BY_CLEANUP;
    }
    const auto found = async_work_.find(handle);
    if (found == async_work_.end()) {
      return ReleaseResult::NOT_REGISTERED;
    }
    registration = found->second;
    async_work_.erase(found);
  }

  registration.release(registration.handle);
  return ReleaseResult::RELEASED;
}

bool NapiEnvironmentOwner::try_add_delivery(DeliveryRegistration registration) {
  if (!valid_registration(registration)) {
    return false;
  }

  std::lock_guard<std::mutex> lock(mutex_);
  if (state_ != State::CREATED && state_ != State::ACTIVE) {
    return false;
  }
  return deliveries_.emplace(registration.handle, registration).second;
}

ReleaseResult NapiEnvironmentOwner::release_delivery(void *handle, bool should_abort) {
  DeliveryRegistration registration{};
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (claimed_deliveries_.find(handle) != claimed_deliveries_.end()) {
      return ReleaseResult::CLAIMED_BY_CLEANUP;
    }
    const auto found = deliveries_.find(handle);
    if (found == deliveries_.end()) {
      return ReleaseResult::NOT_REGISTERED;
    }
    registration = found->second;
    deliveries_.erase(found);
  }

  if (should_abort) {
    registration.abort(registration.handle);
  }
  registration.release(registration.handle);
  return ReleaseResult::RELEASED;
}

bool NapiEnvironmentOwner::try_add_reference(ReferenceRegistration registration) {
  if (!valid_registration(registration)) {
    return false;
  }

  std::lock_guard<std::mutex> lock(mutex_);
  if (state_ != State::CREATED && state_ != State::ACTIVE) {
    return false;
  }
  return references_.emplace(registration.handle, registration).second;
}

ReleaseResult NapiEnvironmentOwner::release_reference(void *handle) {
  ReferenceRegistration registration{};
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (claimed_references_.find(handle) != claimed_references_.end()) {
      return ReleaseResult::CLAIMED_BY_CLEANUP;
    }
    const auto found = references_.find(handle);
    if (found == references_.end()) {
      return ReleaseResult::NOT_REGISTERED;
    }
    registration = found->second;
    references_.erase(found);
  }

  registration.release(registration.handle);
  return ReleaseResult::RELEASED;
}

CleanupResult NapiEnvironmentOwner::cleanup() {
  std::vector<AsyncWorkRegistration> async_to_release;
  std::vector<DeliveryRegistration> deliveries_to_release;
  std::vector<ReferenceRegistration> references_to_release;

  {
    std::unique_lock<std::mutex> lock(mutex_);
    if (state_ == State::CLEANED) {
      return repeated_cleanup_result_locked();
    }
    if (state_ == State::CLOSING) {
      cleanup_complete_.wait(lock, [this] { return state_ == State::CLEANED; });
      return repeated_cleanup_result_locked();
    }

    state_ = State::CLOSING;
    delivery_enabled_ = false;

    async_to_release.reserve(async_work_.size());
    for (const auto &entry : async_work_) {
      claimed_async_.insert(entry.first);
      async_to_release.push_back(entry.second);
    }
    async_work_.clear();

    deliveries_to_release.reserve(deliveries_.size());
    for (const auto &entry : deliveries_) {
      claimed_deliveries_.insert(entry.first);
      deliveries_to_release.push_back(entry.second);
    }
    deliveries_.clear();

    references_to_release.reserve(references_.size());
    for (const auto &entry : references_) {
      claimed_references_.insert(entry.first);
      references_to_release.push_back(entry.second);
    }
    references_.clear();
  }

  for (const auto &registration : async_to_release) {
    registration.request_cancel(registration.handle);
  }
  for (const auto &registration : async_to_release) {
    registration.join(registration.handle);
  }
  for (const auto &registration : deliveries_to_release) {
    registration.abort(registration.handle);
    registration.release(registration.handle);
  }
  for (const auto &registration : references_to_release) {
    registration.release(registration.handle);
  }
  for (const auto &registration : async_to_release) {
    registration.release(registration.handle);
  }

  const cmfa_status shutdown_status = invoke_lifecycle(lifecycle_.shutdown, lifecycle_.context);
  const cmfa_status unregister_status =
      invoke_lifecycle(lifecycle_.unregister_backend, lifecycle_.context);

  {
    std::lock_guard<std::mutex> lock(mutex_);
    cached_shutdown_status_ = shutdown_status;
    cached_unregister_status_ = unregister_status;
    state_ = State::CLEANED;
  }
  cleanup_complete_.notify_all();
  return CleanupResult{false, shutdown_status, unregister_status};
}

std::size_t NapiEnvironmentOwner::async_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return async_work_.size();
}

std::size_t NapiEnvironmentOwner::delivery_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return deliveries_.size();
}

std::size_t NapiEnvironmentOwner::reference_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return references_.size();
}

CleanupResult NapiEnvironmentOwner::repeated_cleanup_result_locked() const {
  return CleanupResult{true, cached_shutdown_status_, cached_unregister_status_};
}

} // namespace cmfa::napi
