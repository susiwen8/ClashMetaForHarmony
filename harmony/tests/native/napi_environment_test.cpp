#include "napi_environment.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <functional>
#include <future>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using cmfa::napi::AsyncWorkRegistration;
using cmfa::napi::CleanupResult;
using cmfa::napi::DeliveryRegistration;
using cmfa::napi::LifecycleOperations;
using cmfa::napi::NapiEnvironmentOwner;
using cmfa::napi::ReferenceRegistration;
using cmfa::napi::ReleaseResult;

class TestFailure : public std::runtime_error {
public:
  explicit TestFailure(const std::string &message) : std::runtime_error(message) {}
};

void expect(bool condition, const std::string &message) {
  if (!condition) {
    throw TestFailure(message);
  }
}

template <typename T, typename U>
void expect_equal(const T &actual, const U &expected, const std::string &message) {
  if (!(actual == expected)) {
    throw TestFailure(message);
  }
}

void expect_strings(const std::vector<std::string> &actual,
                    const std::vector<std::string> &expected,
                    const std::string &message) {
  if (actual != expected) {
    throw TestFailure(message);
  }
}

struct OperationLog {
  std::mutex mutex;
  std::vector<std::string> entries;

  void append(const char *name) {
    std::lock_guard<std::mutex> lock(mutex);
    entries.emplace_back(name);
  }

  std::vector<std::string> snapshot() {
    std::lock_guard<std::mutex> lock(mutex);
    return entries;
  }
};

struct LifecycleContext {
  OperationLog *log = nullptr;
  std::atomic<int> shutdown_count{0};
  std::atomic<int> unregister_count{0};
  cmfa_status shutdown_status = CMFA_OK;
  cmfa_status unregister_status = CMFA_OK;

  explicit LifecycleContext(OperationLog *log_in) : log(log_in) {}
};

cmfa_status lifecycle_shutdown(void *context, cmfa_error *) {
  auto *state = static_cast<LifecycleContext *>(context);
  state->shutdown_count.fetch_add(1, std::memory_order_relaxed);
  state->log->append("core.shutdown");
  return state->shutdown_status;
}

cmfa_status lifecycle_unregister(void *context, cmfa_error *) {
  auto *state = static_cast<LifecycleContext *>(context);
  state->unregister_count.fetch_add(1, std::memory_order_relaxed);
  state->log->append("backend.unregister");
  return state->unregister_status;
}

LifecycleOperations make_lifecycle(LifecycleContext *context) {
  LifecycleOperations operations{};
  operations.context = context;
  operations.shutdown = lifecycle_shutdown;
  operations.unregister_backend = lifecycle_unregister;
  return operations;
}

struct AsyncResource {
  OperationLog *log = nullptr;
  std::atomic<int> cancel_count{0};
  std::atomic<int> join_count{0};
  std::atomic<int> release_count{0};
  std::mutex mutex;
  std::condition_variable cv;
  bool block_join = false;
  bool join_entered = false;
  bool join_allowed = false;
  bool cancel_seen = false;

  explicit AsyncResource(OperationLog *log_in) : log(log_in) {}
};

void async_request_cancel(void *handle) {
  auto *resource = static_cast<AsyncResource *>(handle);
  resource->cancel_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("async.cancel");
  {
    std::lock_guard<std::mutex> lock(resource->mutex);
    resource->cancel_seen = true;
  }
  resource->cv.notify_all();
}

void async_join(void *handle) {
  auto *resource = static_cast<AsyncResource *>(handle);
  resource->join_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("async.join");
  std::unique_lock<std::mutex> lock(resource->mutex);
  resource->join_entered = true;
  resource->cv.notify_all();
  while (resource->block_join && !resource->join_allowed) {
    resource->cv.wait(lock);
  }
}

void async_release(void *handle) {
  auto *resource = static_cast<AsyncResource *>(handle);
  resource->release_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("async.release");
}

AsyncWorkRegistration make_async_registration(AsyncResource *resource) {
  AsyncWorkRegistration registration{};
  registration.handle = resource;
  registration.request_cancel = async_request_cancel;
  registration.join = async_join;
  registration.release = async_release;
  return registration;
}

struct DeliveryResource {
  OperationLog *log = nullptr;
  std::atomic<int> abort_count{0};
  std::atomic<int> release_count{0};

  explicit DeliveryResource(OperationLog *log_in) : log(log_in) {}
};

void delivery_abort(void *handle) {
  auto *resource = static_cast<DeliveryResource *>(handle);
  resource->abort_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("delivery.abort");
}

void delivery_release(void *handle) {
  auto *resource = static_cast<DeliveryResource *>(handle);
  resource->release_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("delivery.release");
}

DeliveryRegistration make_delivery_registration(DeliveryResource *resource) {
  DeliveryRegistration registration{};
  registration.handle = resource;
  registration.abort = delivery_abort;
  registration.release = delivery_release;
  return registration;
}

struct ReferenceResource {
  OperationLog *log = nullptr;
  std::atomic<int> release_count{0};

  explicit ReferenceResource(OperationLog *log_in) : log(log_in) {}
};

void reference_release(void *handle) {
  auto *resource = static_cast<ReferenceResource *>(handle);
  resource->release_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("reference.release");
}

ReferenceRegistration make_reference_registration(ReferenceResource *resource) {
  ReferenceRegistration registration{};
  registration.handle = resource;
  registration.release = reference_release;
  return registration;
}

struct SharedHandleResource {
  OperationLog *log = nullptr;
  std::atomic<int> async_cancel_count{0};
  std::atomic<int> async_join_count{0};
  std::atomic<int> async_release_count{0};
  std::atomic<int> delivery_abort_count{0};
  std::atomic<int> delivery_release_count{0};
  std::atomic<int> reference_release_count{0};
  std::mutex mutex;
  std::condition_variable cv;
  bool block_join = false;
  bool join_entered = false;
  bool join_allowed = false;
  bool cancel_seen = false;

  explicit SharedHandleResource(OperationLog *log_in) : log(log_in) {}
};

void shared_async_request_cancel(void *handle) {
  auto *resource = static_cast<SharedHandleResource *>(handle);
  resource->async_cancel_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("shared.async.cancel");
  {
    std::lock_guard<std::mutex> lock(resource->mutex);
    resource->cancel_seen = true;
  }
  resource->cv.notify_all();
}

void shared_async_join(void *handle) {
  auto *resource = static_cast<SharedHandleResource *>(handle);
  resource->async_join_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("shared.async.join");
  std::unique_lock<std::mutex> lock(resource->mutex);
  resource->join_entered = true;
  resource->cv.notify_all();
  while (resource->block_join && !resource->join_allowed) {
    resource->cv.wait(lock);
  }
}

void shared_async_release(void *handle) {
  auto *resource = static_cast<SharedHandleResource *>(handle);
  resource->async_release_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("shared.async.release");
}

void shared_delivery_abort(void *handle) {
  auto *resource = static_cast<SharedHandleResource *>(handle);
  resource->delivery_abort_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("shared.delivery.abort");
}

void shared_delivery_release(void *handle) {
  auto *resource = static_cast<SharedHandleResource *>(handle);
  resource->delivery_release_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("shared.delivery.release");
}

void shared_reference_release(void *handle) {
  auto *resource = static_cast<SharedHandleResource *>(handle);
  resource->reference_release_count.fetch_add(1, std::memory_order_relaxed);
  resource->log->append("shared.reference.release");
}

AsyncWorkRegistration make_shared_async_registration(SharedHandleResource *resource) {
  AsyncWorkRegistration registration{};
  registration.handle = resource;
  registration.request_cancel = shared_async_request_cancel;
  registration.join = shared_async_join;
  registration.release = shared_async_release;
  return registration;
}

DeliveryRegistration make_shared_delivery_registration(SharedHandleResource *resource) {
  DeliveryRegistration registration{};
  registration.handle = resource;
  registration.abort = shared_delivery_abort;
  registration.release = shared_delivery_release;
  return registration;
}

ReferenceRegistration make_shared_reference_registration(SharedHandleResource *resource) {
  ReferenceRegistration registration{};
  registration.handle = resource;
  registration.release = shared_reference_release;
  return registration;
}

void wait_for_cancel(AsyncResource *resource) {
  std::unique_lock<std::mutex> lock(resource->mutex);
  const bool signaled = resource->cv.wait_for(lock, std::chrono::seconds(2), [&] {
    return resource->cancel_seen;
  });
  expect(signaled, "timed out waiting for async.cancel");
}

void wait_for_join_entry(AsyncResource *resource) {
  std::unique_lock<std::mutex> lock(resource->mutex);
  const bool signaled = resource->cv.wait_for(lock, std::chrono::seconds(2), [&] {
    return resource->join_entered;
  });
  expect(signaled, "timed out waiting for async.join");
}

void allow_join(AsyncResource *resource) {
  {
    std::lock_guard<std::mutex> lock(resource->mutex);
    resource->join_allowed = true;
  }
  resource->cv.notify_all();
}

void expect_cleanup_status(const CleanupResult &result,
                           bool already_cleaned,
                           cmfa_status shutdown_status,
                           cmfa_status unregister_status,
                           const std::string &message) {
  expect_equal(result.already_cleaned, already_cleaned, message + " already_cleaned");
  expect_equal(result.shutdown_status, shutdown_status, message + " shutdown_status");
  expect_equal(result.unregister_status, unregister_status, message + " unregister_status");
}

template <typename Future>
void wait_for_future_ready(Future &future, const std::string &message) {
  expect_equal(future.wait_for(std::chrono::seconds(2)), std::future_status::ready, message);
}

void test_activate_once_and_duplicate_handles_do_not_transfer_ownership() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  AsyncResource async{&log};
  DeliveryResource delivery{&log};
  ReferenceResource reference{&log};
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));

  expect(!owner.can_deliver(), "owner should start with delivery disabled");
  expect(owner.activate(), "first activate should succeed");
  expect(owner.can_deliver(), "activate should enable delivery");
  expect(!owner.activate(), "second activate should fail");

  expect(owner.try_add_async(make_async_registration(&async)), "first async registration should succeed");
  expect(!owner.try_add_async(make_async_registration(&async)), "duplicate async handle should fail");

  expect(owner.try_add_delivery(make_delivery_registration(&delivery)), "first delivery registration should succeed");
  expect(!owner.try_add_delivery(make_delivery_registration(&delivery)), "duplicate delivery handle should fail");

  expect(owner.try_add_reference(make_reference_registration(&reference)), "first reference registration should succeed");
  expect(!owner.try_add_reference(make_reference_registration(&reference)), "duplicate reference handle should fail");

  const CleanupResult cleanup = owner.cleanup();
  expect_cleanup_status(cleanup, false, CMFA_OK, CMFA_OK, "cleanup after duplicates");
  expect_equal(async.release_count.load(std::memory_order_relaxed), 1, "async should release once");
  expect_equal(delivery.abort_count.load(std::memory_order_relaxed), 1, "delivery should abort once");
  expect_equal(delivery.release_count.load(std::memory_order_relaxed), 1, "delivery should release once");
  expect_equal(reference.release_count.load(std::memory_order_relaxed), 1, "reference should release once");
}

void test_handles_are_globally_unique_across_registration_types() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  SharedHandleResource async_then_delivery{&log};
  SharedHandleResource delivery_then_reference{&log};
  SharedHandleResource reference_then_async{&log};
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));

  expect(owner.try_add_async(make_shared_async_registration(&async_then_delivery)),
         "async registration should succeed");
  expect(!owner.try_add_delivery(make_shared_delivery_registration(&async_then_delivery)),
         "delivery registration must reject a handle already owned as async");
  expect_equal(owner.async_count(), static_cast<size_t>(1), "async count should stay at one");
  expect_equal(owner.delivery_count(), static_cast<size_t>(0), "delivery count should stay at zero");

  expect(owner.try_add_delivery(make_shared_delivery_registration(&delivery_then_reference)),
         "delivery registration should succeed");
  expect(!owner.try_add_reference(make_shared_reference_registration(&delivery_then_reference)),
         "reference registration must reject a handle already owned as delivery");
  expect_equal(owner.delivery_count(), static_cast<size_t>(1), "delivery count should stay at one");
  expect_equal(owner.reference_count(), static_cast<size_t>(0), "reference count should stay at zero");

  expect(owner.try_add_reference(make_shared_reference_registration(&reference_then_async)),
         "reference registration should succeed");
  expect(!owner.try_add_async(make_shared_async_registration(&reference_then_async)),
         "async registration must reject a handle already owned as reference");
  expect_equal(owner.reference_count(), static_cast<size_t>(1), "reference count should stay at one");
  expect_equal(owner.async_count(), static_cast<size_t>(1), "async count should still only reflect the first handle");

  const CleanupResult cleanup = owner.cleanup();
  expect_cleanup_status(cleanup, false, CMFA_OK, CMFA_OK, "cleanup after cross-type duplicate attempts");

  expect_equal(async_then_delivery.async_cancel_count.load(std::memory_order_relaxed), 1,
               "accepted async should cancel once");
  expect_equal(async_then_delivery.async_join_count.load(std::memory_order_relaxed), 1,
               "accepted async should join once");
  expect_equal(async_then_delivery.async_release_count.load(std::memory_order_relaxed), 1,
               "accepted async should release once");
  expect_equal(async_then_delivery.delivery_abort_count.load(std::memory_order_relaxed), 0,
               "rejected delivery should not be aborted by owner");
  expect_equal(async_then_delivery.delivery_release_count.load(std::memory_order_relaxed), 0,
               "rejected delivery should not be released by owner");

  expect_equal(delivery_then_reference.delivery_abort_count.load(std::memory_order_relaxed), 1,
               "accepted delivery should abort once");
  expect_equal(delivery_then_reference.delivery_release_count.load(std::memory_order_relaxed), 1,
               "accepted delivery should release once");
  expect_equal(delivery_then_reference.reference_release_count.load(std::memory_order_relaxed), 0,
               "rejected reference should not be released by owner");

  expect_equal(reference_then_async.reference_release_count.load(std::memory_order_relaxed), 1,
               "accepted reference should release once");
  expect_equal(reference_then_async.async_cancel_count.load(std::memory_order_relaxed), 0,
               "rejected async should not be cancelled by owner");
  expect_equal(reference_then_async.async_join_count.load(std::memory_order_relaxed), 0,
               "rejected async should not be joined by owner");
  expect_equal(reference_then_async.async_release_count.load(std::memory_order_relaxed), 0,
               "rejected async should not be released by owner");

  shared_delivery_abort(&async_then_delivery);
  shared_delivery_release(&async_then_delivery);
  shared_reference_release(&delivery_then_reference);
  shared_async_request_cancel(&reference_then_async);
  shared_async_join(&reference_then_async);
  shared_async_release(&reference_then_async);

  expect_equal(async_then_delivery.delivery_abort_count.load(std::memory_order_relaxed), 1,
               "caller must retain rejected delivery ownership");
  expect_equal(async_then_delivery.delivery_release_count.load(std::memory_order_relaxed), 1,
               "caller must release rejected delivery itself");
  expect_equal(delivery_then_reference.reference_release_count.load(std::memory_order_relaxed), 1,
               "caller must retain rejected reference ownership");
  expect_equal(reference_then_async.async_cancel_count.load(std::memory_order_relaxed), 1,
               "caller must retain rejected async cancel ownership");
  expect_equal(reference_then_async.async_join_count.load(std::memory_order_relaxed), 1,
               "caller must retain rejected async join ownership");
  expect_equal(reference_then_async.async_release_count.load(std::memory_order_relaxed), 1,
               "caller must retain rejected async release ownership");
}

void test_normal_release_paths_drop_counts_and_release_once() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  AsyncResource async{&log};
  DeliveryResource delivery{&log};
  ReferenceResource reference{&log};
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));

  expect(owner.try_add_async(make_async_registration(&async)), "async registration should succeed in CREATED");
  expect(owner.try_add_delivery(make_delivery_registration(&delivery)), "delivery registration should succeed in CREATED");
  expect(owner.try_add_reference(make_reference_registration(&reference)), "reference registration should succeed in CREATED");
  expect_equal(owner.async_count(), static_cast<size_t>(1), "async count should track ownership");
  expect_equal(owner.delivery_count(), static_cast<size_t>(1), "delivery count should track ownership");
  expect_equal(owner.reference_count(), static_cast<size_t>(1), "reference count should track ownership");

  expect_equal(owner.finish_async(&async), ReleaseResult::RELEASED, "finish_async should release owned handle");
  expect_equal(owner.release_delivery(&delivery, false), ReleaseResult::RELEASED,
               "release_delivery should release owned handle");
  expect_equal(owner.release_reference(&reference), ReleaseResult::RELEASED,
               "release_reference should release owned handle");
  expect_equal(owner.async_count(), static_cast<size_t>(0), "async count should drop after normal release");
  expect_equal(owner.delivery_count(), static_cast<size_t>(0), "delivery count should drop after normal release");
  expect_equal(owner.reference_count(), static_cast<size_t>(0), "reference count should drop after normal release");

  expect_equal(async.release_count.load(std::memory_order_relaxed), 1, "async normal release should run once");
  expect_equal(delivery.abort_count.load(std::memory_order_relaxed), 0, "normal delivery release should not abort");
  expect_equal(delivery.release_count.load(std::memory_order_relaxed), 1, "delivery normal release should run once");
  expect_equal(reference.release_count.load(std::memory_order_relaxed), 1, "reference normal release should run once");

  expect_equal(owner.finish_async(&async), ReleaseResult::NOT_REGISTERED, "released async should disappear");
  expect_equal(owner.release_delivery(&delivery, false), ReleaseResult::NOT_REGISTERED,
               "released delivery should disappear");
  expect_equal(owner.release_reference(&reference), ReleaseResult::NOT_REGISTERED,
               "released reference should disappear");
}

void test_release_delivery_abort_true_runs_abort_then_release_once() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  DeliveryResource delivery{&log};
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));

  expect(owner.try_add_delivery(make_delivery_registration(&delivery)), "delivery registration should succeed");
  expect_equal(owner.release_delivery(&delivery, true), ReleaseResult::RELEASED,
               "release_delivery(true) should release owned delivery");
  expect_equal(owner.delivery_count(), static_cast<size_t>(0), "delivery count should drop to zero");
  expect_strings(log.snapshot(), {"delivery.abort", "delivery.release"},
                 "release_delivery(true) must abort before release");
  expect_equal(delivery.abort_count.load(std::memory_order_relaxed), 1, "abort should run once");
  expect_equal(delivery.release_count.load(std::memory_order_relaxed), 1, "release should run once");
  expect_equal(owner.release_delivery(&delivery, true), ReleaseResult::NOT_REGISTERED,
               "released delivery should not stay registered");
}

void test_invalid_registrations_are_rejected_without_transferring_ownership() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  AsyncResource async{&log};
  DeliveryResource delivery{&log};
  ReferenceResource reference{&log};
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));

  AsyncWorkRegistration null_async = make_async_registration(&async);
  null_async.handle = nullptr;
  expect(!owner.try_add_async(null_async), "async null handle must fail");

  AsyncWorkRegistration missing_async_cancel = make_async_registration(&async);
  missing_async_cancel.request_cancel = nullptr;
  expect(!owner.try_add_async(missing_async_cancel), "async missing cancel callback must fail");

  DeliveryRegistration null_delivery = make_delivery_registration(&delivery);
  null_delivery.handle = nullptr;
  expect(!owner.try_add_delivery(null_delivery), "delivery null handle must fail");

  DeliveryRegistration missing_delivery_abort = make_delivery_registration(&delivery);
  missing_delivery_abort.abort = nullptr;
  expect(!owner.try_add_delivery(missing_delivery_abort), "delivery missing abort callback must fail");

  ReferenceRegistration null_reference = make_reference_registration(&reference);
  null_reference.handle = nullptr;
  expect(!owner.try_add_reference(null_reference), "reference null handle must fail");

  ReferenceRegistration missing_reference_release = make_reference_registration(&reference);
  missing_reference_release.release = nullptr;
  expect(!owner.try_add_reference(missing_reference_release), "reference missing release callback must fail");

  expect_equal(owner.async_count(), static_cast<size_t>(0), "invalid async registrations must not change count");
  expect_equal(owner.delivery_count(), static_cast<size_t>(0), "invalid delivery registrations must not change count");
  expect_equal(owner.reference_count(), static_cast<size_t>(0),
               "invalid reference registrations must not change count");

  const CleanupResult cleanup = owner.cleanup();
  expect_cleanup_status(cleanup, false, CMFA_OK, CMFA_OK, "cleanup after invalid registrations");
  expect_equal(async.cancel_count.load(std::memory_order_relaxed), 0, "invalid async should not transfer cancel ownership");
  expect_equal(async.join_count.load(std::memory_order_relaxed), 0, "invalid async should not transfer join ownership");
  expect_equal(async.release_count.load(std::memory_order_relaxed), 0, "invalid async should not transfer release ownership");
  expect_equal(delivery.abort_count.load(std::memory_order_relaxed), 0,
               "invalid delivery should not transfer abort ownership");
  expect_equal(delivery.release_count.load(std::memory_order_relaxed), 0,
               "invalid delivery should not transfer release ownership");
  expect_equal(reference.release_count.load(std::memory_order_relaxed), 0,
               "invalid reference should not transfer release ownership");
}

void test_cleanup_exact_order_and_delivery_gate_stays_closed() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  AsyncResource async{&log};
  DeliveryResource delivery{&log};
  ReferenceResource reference{&log};
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));
  int js_delivery_attempts = 0;

  expect(owner.try_add_async(make_async_registration(&async)), "setup async registration should succeed");
  expect(owner.try_add_delivery(make_delivery_registration(&delivery)), "setup delivery registration should succeed");
  expect(owner.try_add_reference(make_reference_registration(&reference)), "setup reference registration should succeed");
  expect(owner.activate(), "activate should succeed");

  const CleanupResult cleanup = owner.cleanup();

  expect_cleanup_status(cleanup, false, CMFA_OK, CMFA_OK, "exact cleanup");
  expect_strings(log.snapshot(),
                 {"async.cancel",
                  "async.join",
                  "delivery.abort",
                  "delivery.release",
                  "reference.release",
                  "async.release",
                  "core.shutdown",
                  "backend.unregister"},
                 "cleanup should follow the required teardown order");
  expect_equal(delivery.abort_count.load(std::memory_order_relaxed), 1, "delivery abort should happen once");
  expect_equal(delivery.release_count.load(std::memory_order_relaxed), 1, "delivery release should happen once");
  expect_equal(reference.release_count.load(std::memory_order_relaxed), 1, "reference cleanup should happen once");
  expect_equal(async.release_count.load(std::memory_order_relaxed), 1, "async cleanup should happen once");
  expect_equal(lifecycle.shutdown_count.load(std::memory_order_relaxed), 1, "shutdown should happen after drain");
  expect_equal(lifecycle.unregister_count.load(std::memory_order_relaxed), 1, "unregister should happen after shutdown");
  expect(!owner.can_deliver(), "cleanup should permanently disable delivery");
  if (owner.can_deliver()) {
    js_delivery_attempts += 1;
  }
  expect_equal(js_delivery_attempts, 0, "fake JS delivery gate should stay closed after cleanup");
}

void test_cleanup_rejects_late_registrations_and_claims_release_races() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  AsyncResource async{&log};
  async.block_join = true;
  DeliveryResource existing_delivery{&log};
  DeliveryResource late_delivery{&log};
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));

  expect(owner.activate(), "activate should succeed");
  expect(owner.try_add_async(make_async_registration(&async)), "async registration should succeed");
  expect(owner.try_add_delivery(make_delivery_registration(&existing_delivery)), "existing delivery should register");

  auto cleanup_future = std::async(std::launch::async, [&owner]() { return owner.cleanup(); });
  wait_for_cancel(&async);
  wait_for_join_entry(&async);

  expect(!owner.can_deliver(), "cleanup should close the delivery gate before teardown completes");
  expect(!owner.try_add_delivery(make_delivery_registration(&late_delivery)),
         "late registration should fail once cleanup starts");
  expect_equal(owner.finish_async(&async), ReleaseResult::CLAIMED_BY_CLEANUP,
               "cleanup should claim async release ownership");
  expect_equal(late_delivery.release_count.load(std::memory_order_relaxed), 0,
               "late delivery should remain caller-owned");

  allow_join(&async);
  const CleanupResult cleanup = cleanup_future.get();
  expect_cleanup_status(cleanup, false, CMFA_OK, CMFA_OK, "cleanup after race");
  expect_equal(async.release_count.load(std::memory_order_relaxed), 1,
               "cleanup should release claimed async exactly once");
}

void test_cleanup_claims_async_delivery_and_reference_release_paths() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  AsyncResource async{&log};
  DeliveryResource delivery{&log};
  ReferenceResource reference{&log};
  async.block_join = true;
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));

  expect(owner.activate(), "activate should succeed");
  expect(owner.try_add_async(make_async_registration(&async)), "async registration should succeed");
  expect(owner.try_add_delivery(make_delivery_registration(&delivery)), "delivery registration should succeed");
  expect(owner.try_add_reference(make_reference_registration(&reference)), "reference registration should succeed");

  auto cleanup_future = std::async(std::launch::async, [&owner]() { return owner.cleanup(); });
  wait_for_cancel(&async);
  wait_for_join_entry(&async);

  expect_equal(owner.finish_async(&async), ReleaseResult::CLAIMED_BY_CLEANUP,
               "claimed async must stay cleanup-owned");
  expect_equal(owner.release_delivery(&delivery, true), ReleaseResult::CLAIMED_BY_CLEANUP,
               "claimed delivery must stay cleanup-owned");
  expect_equal(owner.release_reference(&reference), ReleaseResult::CLAIMED_BY_CLEANUP,
               "claimed reference must stay cleanup-owned");
  expect_equal(delivery.abort_count.load(std::memory_order_relaxed), 0,
               "caller must not abort cleanup-claimed delivery");
  expect_equal(delivery.release_count.load(std::memory_order_relaxed), 0,
               "caller must not release cleanup-claimed delivery");
  expect_equal(reference.release_count.load(std::memory_order_relaxed), 0,
               "caller must not release cleanup-claimed reference");

  allow_join(&async);
  const CleanupResult cleanup = cleanup_future.get();
  expect_cleanup_status(cleanup, false, CMFA_OK, CMFA_OK, "cleanup claim race");
  expect_equal(async.release_count.load(std::memory_order_relaxed), 1, "cleanup must release async once");
  expect_equal(delivery.abort_count.load(std::memory_order_relaxed), 1, "cleanup must abort delivery once");
  expect_equal(delivery.release_count.load(std::memory_order_relaxed), 1, "cleanup must release delivery once");
  expect_equal(reference.release_count.load(std::memory_order_relaxed), 1,
               "cleanup must release reference once");
}

void test_cleanup_waits_for_in_flight_async_and_reuses_cached_result() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  AsyncResource async{&log};
  async.block_join = true;
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));

  expect(owner.activate(), "activate should succeed");
  expect(owner.try_add_async(make_async_registration(&async)), "async registration should succeed");

  auto first_cleanup = std::async(std::launch::async, [&owner]() { return owner.cleanup(); });
  wait_for_cancel(&async);
  wait_for_join_entry(&async);

  std::promise<void> second_cleanup_started;
  auto second_cleanup_started_future = second_cleanup_started.get_future();
  auto second_cleanup = std::async(std::launch::async, [&owner, &second_cleanup_started]() {
    second_cleanup_started.set_value();
    return owner.cleanup();
  });
  wait_for_future_ready(second_cleanup_started_future, "second cleanup thread should start after first enters join");

  allow_join(&async);

  const CleanupResult first = first_cleanup.get();
  const CleanupResult second = second_cleanup.get();
  const CleanupResult third = owner.cleanup();

  expect_cleanup_status(first, false, CMFA_OK, CMFA_OK, "first cleanup result");
  expect_cleanup_status(second, true, CMFA_OK, CMFA_OK, "second cleanup result");
  expect_cleanup_status(third, true, CMFA_OK, CMFA_OK, "sequential cleanup result");
  expect_equal(async.cancel_count.load(std::memory_order_relaxed), 1, "cancel should happen once");
  expect_equal(async.join_count.load(std::memory_order_relaxed), 1, "join should happen once");
  expect_equal(async.release_count.load(std::memory_order_relaxed), 1, "release should happen once");
  expect_equal(lifecycle.shutdown_count.load(std::memory_order_relaxed), 1, "shutdown should happen once");
  expect_equal(lifecycle.unregister_count.load(std::memory_order_relaxed), 1, "unregister should happen once");
}

void test_cleanup_preserves_independent_shutdown_and_unregister_statuses() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  lifecycle.shutdown_status = CMFA_BACKEND_ERROR;
  lifecycle.unregister_status = CMFA_INVALID_STATE;
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));

  const CleanupResult cleanup = owner.cleanup();

  expect_cleanup_status(cleanup, false, CMFA_BACKEND_ERROR, CMFA_INVALID_STATE, "status-preserving cleanup");
  expect_strings(log.snapshot(), {"core.shutdown", "backend.unregister"},
                 "cleanup should attempt unregister even when shutdown fails");
}

void test_cleanup_before_activate_drains_partial_initialization() {
  OperationLog log;
  LifecycleContext lifecycle{&log};
  AsyncResource async{&log};
  DeliveryResource delivery{&log};
  ReferenceResource reference{&log};
  NapiEnvironmentOwner owner(make_lifecycle(&lifecycle));

  expect(owner.try_add_async(make_async_registration(&async)), "CREATED async registration should succeed");
  expect(owner.try_add_delivery(make_delivery_registration(&delivery)), "CREATED delivery registration should succeed");
  expect(owner.try_add_reference(make_reference_registration(&reference)), "CREATED reference registration should succeed");

  const CleanupResult cleanup = owner.cleanup();

  expect_cleanup_status(cleanup, false, CMFA_OK, CMFA_OK, "partial-init cleanup");
  expect_equal(async.release_count.load(std::memory_order_relaxed), 1, "partial-init async should release once");
  expect_equal(delivery.abort_count.load(std::memory_order_relaxed), 1, "partial-init delivery should abort once");
  expect_equal(delivery.release_count.load(std::memory_order_relaxed), 1, "partial-init delivery should release once");
  expect_equal(reference.release_count.load(std::memory_order_relaxed), 1,
               "partial-init reference should release once");
}

void test_destructor_uses_cleanup_path_exactly_once() {
  OperationLog explicit_log;
  LifecycleContext explicit_lifecycle{&explicit_log};
  AsyncResource explicit_async{&explicit_log};
  DeliveryResource explicit_delivery{&explicit_log};
  ReferenceResource explicit_reference{&explicit_log};
  {
    NapiEnvironmentOwner owner(make_lifecycle(&explicit_lifecycle));
    expect(owner.try_add_async(make_async_registration(&explicit_async)), "explicit async registration should succeed");
    expect(owner.try_add_delivery(make_delivery_registration(&explicit_delivery)),
           "explicit delivery registration should succeed");
    expect(owner.try_add_reference(make_reference_registration(&explicit_reference)),
           "explicit reference registration should succeed");
    const CleanupResult cleanup = owner.cleanup();
    expect_cleanup_status(cleanup, false, CMFA_OK, CMFA_OK, "explicit cleanup before destructor");
  }

  expect_equal(explicit_async.release_count.load(std::memory_order_relaxed), 1,
               "destructor must not re-release explicit-cleaned async");
  expect_equal(explicit_delivery.abort_count.load(std::memory_order_relaxed), 1,
               "destructor must not re-abort explicit-cleaned delivery");
  expect_equal(explicit_delivery.release_count.load(std::memory_order_relaxed), 1,
               "destructor must not re-release explicit-cleaned delivery");
  expect_equal(explicit_reference.release_count.load(std::memory_order_relaxed), 1,
               "destructor must not re-release explicit-cleaned reference");
  expect_equal(explicit_lifecycle.shutdown_count.load(std::memory_order_relaxed), 1,
               "destructor must not re-run shutdown after explicit cleanup");
  expect_equal(explicit_lifecycle.unregister_count.load(std::memory_order_relaxed), 1,
               "destructor must not re-run unregister after explicit cleanup");

  OperationLog implicit_log;
  LifecycleContext implicit_lifecycle{&implicit_log};
  AsyncResource implicit_async{&implicit_log};
  DeliveryResource implicit_delivery{&implicit_log};
  ReferenceResource implicit_reference{&implicit_log};
  {
    NapiEnvironmentOwner owner(make_lifecycle(&implicit_lifecycle));
    expect(owner.try_add_async(make_async_registration(&implicit_async)), "implicit async registration should succeed");
    expect(owner.try_add_delivery(make_delivery_registration(&implicit_delivery)),
           "implicit delivery registration should succeed");
    expect(owner.try_add_reference(make_reference_registration(&implicit_reference)),
           "implicit reference registration should succeed");
  }

  expect_equal(implicit_async.cancel_count.load(std::memory_order_relaxed), 1,
               "destructor should cancel implicit async once");
  expect_equal(implicit_async.join_count.load(std::memory_order_relaxed), 1,
               "destructor should join implicit async once");
  expect_equal(implicit_async.release_count.load(std::memory_order_relaxed), 1,
               "destructor should release implicit async once");
  expect_equal(implicit_delivery.abort_count.load(std::memory_order_relaxed), 1,
               "destructor should abort implicit delivery once");
  expect_equal(implicit_delivery.release_count.load(std::memory_order_relaxed), 1,
               "destructor should release implicit delivery once");
  expect_equal(implicit_reference.release_count.load(std::memory_order_relaxed), 1,
               "destructor should release implicit reference once");
  expect_equal(implicit_lifecycle.shutdown_count.load(std::memory_order_relaxed), 1,
               "destructor should run shutdown once");
  expect_equal(implicit_lifecycle.unregister_count.load(std::memory_order_relaxed), 1,
               "destructor should run unregister once");
}

} // namespace

int main() {
  const std::vector<std::pair<const char *, std::function<void()>>> tests = {
      {"activate_once_and_duplicate_handles_do_not_transfer_ownership",
       test_activate_once_and_duplicate_handles_do_not_transfer_ownership},
      {"handles_are_globally_unique_across_registration_types",
       test_handles_are_globally_unique_across_registration_types},
      {"normal_release_paths_drop_counts_and_release_once", test_normal_release_paths_drop_counts_and_release_once},
      {"release_delivery_abort_true_runs_abort_then_release_once",
       test_release_delivery_abort_true_runs_abort_then_release_once},
      {"invalid_registrations_are_rejected_without_transferring_ownership",
       test_invalid_registrations_are_rejected_without_transferring_ownership},
      {"cleanup_exact_order_and_delivery_gate_stays_closed", test_cleanup_exact_order_and_delivery_gate_stays_closed},
      {"cleanup_rejects_late_registrations_and_claims_release_races",
       test_cleanup_rejects_late_registrations_and_claims_release_races},
      {"cleanup_claims_async_delivery_and_reference_release_paths",
       test_cleanup_claims_async_delivery_and_reference_release_paths},
      {"cleanup_waits_for_in_flight_async_and_reuses_cached_result",
       test_cleanup_waits_for_in_flight_async_and_reuses_cached_result},
      {"cleanup_preserves_independent_shutdown_and_unregister_statuses",
       test_cleanup_preserves_independent_shutdown_and_unregister_statuses},
      {"cleanup_before_activate_drains_partial_initialization",
       test_cleanup_before_activate_drains_partial_initialization},
      {"destructor_uses_cleanup_path_exactly_once", test_destructor_uses_cleanup_path_exactly_once},
  };

  size_t failed = 0;
  for (const auto &entry : tests) {
    try {
      entry.second();
      std::cout << "[PASS] " << entry.first << '\n';
    } catch (const std::exception &error) {
      failed += 1;
      std::cerr << "[FAIL] " << entry.first << ": " << error.what() << '\n';
    }
  }

  if (failed != 0) {
    std::cerr << failed << " test(s) failed\n";
    return 1;
  }

  std::cout << tests.size() << " test(s) passed\n";
  return 0;
}
