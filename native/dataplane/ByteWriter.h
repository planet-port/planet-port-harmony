// ByteWriter.h — 大端流构造器（Arp/Ndp 报文共用，地基，Task 0）
//
// 直译源：ArpTable.kt 内联 ByteWriter。
#pragma once
#include <cstdint>
#include <vector>
namespace pp {

class ByteWriter {
public:
    explicit ByteWriter(size_t cap = 64) { m_buf.reserve(cap); }
    void u8(uint8_t v) { m_buf.push_back(v); }
    void u16(uint16_t v) {
        m_buf.push_back(uint8_t(v >> 8));
        m_buf.push_back(uint8_t(v));
    }
    void u32(uint32_t v) {
        u16(uint16_t(v >> 16));
        u16(uint16_t(v));
    }
    void mac(uint64_t m) { // 6 字节，高字节在前
        for (int i = 5; i >= 0; --i) m_buf.push_back(uint8_t(m >> (8 * i)));
    }
    void ip(uint32_t v) { // 4 字节大端（网络序）
        u8(uint8_t(v >> 24));
        u8(uint8_t(v >> 16));
        u8(uint8_t(v >> 8));
        u8(uint8_t(v));
    }
    void bytes(const uint8_t* p, size_t n) { m_buf.insert(m_buf.end(), p, p + n); }
    std::vector<uint8_t> build() { return std::move(m_buf); }
    size_t size() const { return m_buf.size(); }

private:
    std::vector<uint8_t> m_buf;
};

} // namespace pp
