#ifndef CMFA_NAPI_ENVIRONMENT_H
#define CMFA_NAPI_ENVIRONMENT_H

#include "cmfa_types.h"

#include <condition_variable>
#include <cstddef>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

namespace cmfa::napi {

struct AsyncWorkRegistration {
  void *handle;
  void (*request_cancel)(void *);
  void (*join)(void *);
  void (*release)(void *);
};

struct DeliveryRegistration {
  void *handle;
  void (*abort)(void *);
  void (*release)(void *);
};

struct ReferenceRegistration {
  void *handle;
  void (*release)(void *);
};

struct LifecycleOperations {
  void *context;
  cmfa_status (*shutdown)(void *context, cmfa_error *error);
  cmfa_status (*unregister_backend)(void *context, cmfa_error *error);
};

struct CleanupResult {
  bool already_cleaned;
  cmfa_status shutdown_status;
  cmfa_status unregister_status;
};

enum class ReleaseResult {
  RELEASED,
  CLAIMED_BY_CLEANUP,
  NOT_REGISTERED,
};

class NapiEnvironmentOwner final {
public:
  explicit NapiEnvironmentOwner(LifecycleOperations operations);
  ~NapiEnvironmentOwner();

  NapiEnvironmentOwner(const NapiEnvironmentOwner &) = delete;
  NapiEnvironmentOwner &operator=(const NapiEnvironmentOwner &) = delete;

  bool activate();
  bool can_deliver() const;

  bool try_add_async(AsyncWorkRegistration registration);
  ReleaseResult finish_async(void *handle);

  bool try_add_delivery(DeliveryRegistration registration);
  ReleaseResult release_delivery(void *handle, bool abort);

  bool try_add_reference(ReferenceRegistration registration);
  ReleaseResult release_reference(void *handle);

  CleanupResult cleanup();

  std::size_t async_count() const;
  std::size_t delivery_count() const;
  std::size_t reference_count() const;

private:
  enum class State {
    CREATED,
    ACTIVE,
    CLOSING,
    CLEANED,
  };

  CleanupResult repeated_cleanup_result_locked() const;

  LifecycleOperations lifecycle_;
  mutable std::mutex mutex_;
  std::condition_variable cleanup_complete_;
  State state_;
  bool delivery_enabled_;
  std::unordered_map<void *, AsyncWorkRegistration> async_work_;
  std::unordered_map<void *, DeliveryRegistration> deliveries_;
  std::unordered_map<void *, ReferenceRegistration> references_;
  std::unordered_set<void *> claimed_async_;
  std::unordered_set<void *> claimed_deliveries_;
  std::unordered_set<void *> claimed_references_;
  cmfa_status cached_shutdown_status_;
  cmfa_status cached_unregister_status_;
};

} // namespace cmfa::napi

#endif
