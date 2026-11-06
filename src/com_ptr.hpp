#pragma once
#include <utility>

namespace oit {
template<class T> class ComPtr {
    T* value_ = nullptr;
public:
    ComPtr() = default;
    explicit ComPtr(T* value) : value_(value) { if (value_) value_->AddRef(); }
    ComPtr(const ComPtr& other) : ComPtr(other.value_) {}
    ComPtr(ComPtr&& other) noexcept : value_(std::exchange(other.value_, nullptr)) {}
    ~ComPtr() { if (value_) value_->Release(); }
    ComPtr& operator=(ComPtr other) noexcept { std::swap(value_, other.value_); return *this; }
    T* get() const { return value_; }
    T* operator->() const { return value_; }
    explicit operator bool() const { return value_ != nullptr; }
    T** put() { if (value_) value_->Release(); value_ = nullptr; return &value_; }
    T* detach() { return std::exchange(value_, nullptr); }
};
}

