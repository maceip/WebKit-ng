#pragma once

#include "core/Result.h"

#include <cstdint>
#include <string>
#include <vector>

namespace ng {

using BrowserWindowId = uint64_t;
using BrowserTabId = uint64_t;

enum class TabStripMode {
    Horizontal,
    Vertical,
};

struct BrowserTab {
    BrowserTabId id { 0 };
    BrowserWindowId windowId { 0 };
    std::string url;
    std::string title;
    bool active { false };
    bool pinned { false };
    bool discarded { false };
};

struct BrowserWindow {
    BrowserWindowId id { 0 };
    TabStripMode tabStripMode { TabStripMode::Horizontal };
    std::vector<BrowserTabId> tabs;
    BrowserTabId activeTabId { 0 };
};

class BrowserStateModel {
public:
    BrowserWindowId createWindow(TabStripMode = TabStripMode::Horizontal);
    Result<BrowserTabId> createTab(BrowserWindowId, std::string url, bool activate);
    Result<void> closeTab(BrowserTabId);
    Result<void> activateTab(BrowserTabId);
    Result<void> moveTab(BrowserTabId, BrowserWindowId targetWindow, size_t targetIndex);
    Result<void> setTabStripMode(BrowserWindowId, TabStripMode);

    const BrowserWindow* window(BrowserWindowId) const;
    const BrowserTab* tab(BrowserTabId) const;
    std::vector<BrowserWindow> windows() const { return m_windows; }
    std::vector<BrowserTab> tabs() const { return m_tabs; }

private:
    BrowserWindow* mutableWindow(BrowserWindowId);
    BrowserTab* mutableTab(BrowserTabId);
    void removeTabFromWindow(BrowserWindow&, BrowserTabId);
    void setActiveTab(BrowserWindow&, BrowserTabId);

    BrowserWindowId m_nextWindowId { 1 };
    BrowserTabId m_nextTabId { 1 };
    std::vector<BrowserWindow> m_windows;
    std::vector<BrowserTab> m_tabs;
};

} // namespace ng

