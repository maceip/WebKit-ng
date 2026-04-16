#include "tabs/BrowserCommandController.h"

namespace ng {

BrowserCommandController::BrowserCommandController(BrowserStateModel& state)
    : m_state(state)
{
}

BrowserWindowId BrowserCommandController::newWindow(TabStripMode mode)
{
    return m_state.createWindow(mode);
}

Result<BrowserTabId> BrowserCommandController::newTab(BrowserWindowId windowId, std::string url, bool activate)
{
    return m_state.createTab(windowId, std::move(url), activate);
}

Result<void> BrowserCommandController::closeTab(BrowserTabId tabId)
{
    return m_state.closeTab(tabId);
}

Result<void> BrowserCommandController::selectTab(BrowserTabId tabId)
{
    return m_state.activateTab(tabId);
}

Result<void> BrowserCommandController::moveTab(BrowserTabId tabId, BrowserWindowId windowId, size_t targetIndex)
{
    return m_state.moveTab(tabId, windowId, targetIndex);
}

Result<void> BrowserCommandController::useHorizontalTabs(BrowserWindowId windowId)
{
    return m_state.setTabStripMode(windowId, TabStripMode::Horizontal);
}

Result<void> BrowserCommandController::useVerticalTabs(BrowserWindowId windowId)
{
    return m_state.setTabStripMode(windowId, TabStripMode::Vertical);
}

} // namespace ng

