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

  auto second_cleanup = std::async(std::launch::async, [&owner]() { return owner.cleanup(); });
  expect_equal(second_cleanup.wait_for(std::chrono::milliseconds(0)),
               std::future_status::timeout,
               "concurrent cleanup should wait for the first cleanup result");

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

} // namespace

int main() {
  const std::vector<std::pair<const char *, std::function<void()>>> tests = {
      {"activate_once_and_duplicate_handles_do_not_transfer_ownership",
       test_activate_once_and_duplicate_handles_do_not_transfer_ownership},
      {"normal_release_paths_drop_counts_and_release_once", test_normal_release_paths_drop_counts_and_release_once},
      {"cleanup_exact_order_and_delivery_gate_stays_closed", test_cleanup_exact_order_and_delivery_gate_stays_closed},
      {"cleanup_rejects_late_registrations_and_claims_release_races",
       test_cleanup_rejects_late_registrations_and_claims_release_races},
      {"cleanup_waits_for_in_flight_async_and_reuses_cached_result",
       test_cleanup_waits_for_in_flight_async_and_reuses_cached_result},
      {"cleanup_preserves_independent_shutdown_and_unregister_statuses",
       test_cleanup_preserves_independent_shutdown_and_unregister_statuses},
      {"cleanup_before_activate_drains_partial_initialization",
       test_cleanup_before_activate_drains_partial_initialization},
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
