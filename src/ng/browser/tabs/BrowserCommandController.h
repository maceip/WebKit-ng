#pragma once

#include "tabs/BrowserStateModel.h"

namespace ng {

class BrowserCommandController {
public:
    explicit BrowserCommandController(BrowserStateModel&);

    BrowserWindowId newWindow(TabStripMode);
    Result<BrowserTabId> newTab(BrowserWindowId, std::string url, bool activate = true);
    Result<void> closeTab(BrowserTabId);
    Result<void> selectTab(BrowserTabId);
    Result<void> moveTab(BrowserTabId, BrowserWindowId, size_t targetIndex);
    Result<void> useHorizontalTabs(BrowserWindowId);
    Result<void> useVerticalTabs(BrowserWindowId);

private:
    BrowserStateModel& m_state;
};

} // namespace ng

