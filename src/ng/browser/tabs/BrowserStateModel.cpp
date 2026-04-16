#include "tabs/BrowserStateModel.h"

#include <algorithm>

namespace ng {

BrowserWindowId BrowserStateModel::createWindow(TabStripMode mode)
{
    BrowserWindow window;
    window.id = m_nextWindowId++;
    window.tabStripMode = mode;
    m_windows.push_back(window);
    return window.id;
}

Result<BrowserTabId> BrowserStateModel::createTab(BrowserWindowId windowId, std::string url, bool activate)
{
    auto* targetWindow = mutableWindow(windowId);
    if (!targetWindow)
        return Result<BrowserTabId>::fail({ ErrorCode::NotFound, "window not found" });

    BrowserTab tab;
    tab.id = m_nextTabId++;
    tab.windowId = windowId;
    tab.url = std::move(url);
    tab.active = activate || targetWindow->tabs.empty();

    targetWindow->tabs.push_back(tab.id);
    m_tabs.push_back(tab);

    if (tab.active)
        setActiveTab(*targetWindow, tab.id);

    return Result<BrowserTabId>::ok(tab.id);
}

Result<void> BrowserStateModel::closeTab(BrowserTabId tabId)
{
    auto tabIt = std::find_if(m_tabs.begin(), m_tabs.end(), [tabId](const auto& tab) { return tab.id == tabId; });
    if (tabIt == m_tabs.end())
        return Result<void>::fail({ ErrorCode::NotFound, "tab not found" });

    auto* ownerWindow = mutableWindow(tabIt->windowId);
    if (ownerWindow) {
        removeTabFromWindow(*ownerWindow, tabId);
        if (ownerWindow->activeTabId == tabId)
            ownerWindow->activeTabId = ownerWindow->tabs.empty() ? 0 : ownerWindow->tabs.front();
    }

    m_tabs.erase(tabIt);
    if (ownerWindow && ownerWindow->activeTabId)
        setActiveTab(*ownerWindow, ownerWindow->activeTabId);

    return Result<void>::ok();
}

Result<void> BrowserStateModel::activateTab(BrowserTabId tabId)
{
    auto* tab = mutableTab(tabId);
    if (!tab)
        return Result<void>::fail({ ErrorCode::NotFound, "tab not found" });

    auto* ownerWindow = mutableWindow(tab->windowId);
    if (!ownerWindow)
        return Result<void>::fail({ ErrorCode::NotFound, "window not found" });

    setActiveTab(*ownerWindow, tabId);
    return Result<void>::ok();
}

Result<void> BrowserStateModel::moveTab(BrowserTabId tabId, BrowserWindowId targetWindowId, size_t targetIndex)
{
    auto* tab = mutableTab(tabId);
    if (!tab)
        return Result<void>::fail({ ErrorCode::NotFound, "tab not found" });

    auto* sourceWindow = mutableWindow(tab->windowId);
    auto* targetWindow = mutableWindow(targetWindowId);
    if (!sourceWindow || !targetWindow)
        return Result<void>::fail({ ErrorCode::NotFound, "window not found" });

    removeTabFromWindow(*sourceWindow, tabId);
    targetIndex = std::min(targetIndex, targetWindow->tabs.size());
    targetWindow->tabs.insert(targetWindow->tabs.begin() + static_cast<std::vector<BrowserTabId>::difference_type>(targetIndex), tabId);
    tab->windowId = targetWindowId;

    if (sourceWindow->activeTabId == tabId)
        sourceWindow->activeTabId = sourceWindow->tabs.empty() ? 0 : sourceWindow->tabs.front();

    setActiveTab(*targetWindow, tabId);
    return Result<void>::ok();
}

Result<void> BrowserStateModel::setTabStripMode(BrowserWindowId windowId, TabStripMode mode)
{
    auto* targetWindow = mutableWindow(windowId);
    if (!targetWindow)
        return Result<void>::fail({ ErrorCode::NotFound, "window not found" });

    targetWindow->tabStripMode = mode;
    return Result<void>::ok();
}

const BrowserWindow* BrowserStateModel::window(BrowserWindowId id) const
{
    auto it = std::find_if(m_windows.begin(), m_windows.end(), [id](const auto& window) { return window.id == id; });
    return it == m_windows.end() ? nullptr : &*it;
}

const BrowserTab* BrowserStateModel::tab(BrowserTabId id) const
{
    auto it = std::find_if(m_tabs.begin(), m_tabs.end(), [id](const auto& tab) { return tab.id == id; });
    return it == m_tabs.end() ? nullptr : &*it;
}

BrowserWindow* BrowserStateModel::mutableWindow(BrowserWindowId id)
{
    auto it = std::find_if(m_windows.begin(), m_windows.end(), [id](const auto& window) { return window.id == id; });
    return it == m_windows.end() ? nullptr : &*it;
}

BrowserTab* BrowserStateModel::mutableTab(BrowserTabId id)
{
    auto it = std::find_if(m_tabs.begin(), m_tabs.end(), [id](const auto& tab) { return tab.id == id; });
    return it == m_tabs.end() ? nullptr : &*it;
}

void BrowserStateModel::removeTabFromWindow(BrowserWindow& window, BrowserTabId tabId)
{
    window.tabs.erase(std::remove(window.tabs.begin(), window.tabs.end(), tabId), window.tabs.end());
}

void BrowserStateModel::setActiveTab(BrowserWindow& window, BrowserTabId tabId)
{
    window.activeTabId = tabId;
    for (auto& tab : m_tabs)
        tab.active = tab.windowId == window.id && tab.id == tabId;
}

} // namespace ng

