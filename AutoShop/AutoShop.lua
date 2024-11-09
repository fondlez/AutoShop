local _G, env = getfenv(0), {}
setmetatable(env, { __index = _G })
setfenv(1, env)

local BuyMerchantItem = BuyMerchantItem
local BuybackItem = BuybackItem
local CanMerchantRepair = CanMerchantRepair
local ClearCursor = ClearCursor
local CloseDropDownMenus = CloseDropDownMenus
local GameFontNormal = GameFontNormal
local GameFontNormalSmall = GameFontNormalSmall
local GetBuildInfo = GetBuildInfo
local GetBuybackItemInfo = GetBuybackItemInfo
local GetBuybackItemLink = GetBuybackItemLink -- tbc+
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerItemLink = GetContainerItemLink
local GetContainerNumSlots = GetContainerNumSlots
local GetCurrentKeyBoardFocus = GetCurrentKeyBoardFocus -- tbc+
local GetCursorInfo = GetCursorInfo -- tbc+
local GetItemCount = GetItemCount -- tbc+
local GetItemInfo = GetItemInfo
local GetMerchantItemInfo = GetMerchantItemInfo
local GetMerchantItemLink = GetMerchantItemLink
local GetMerchantItemMaxStack = GetMerchantItemMaxStack
local GetMerchantNumItems = GetMerchantNumItems
local GetMoney = GetMoney
local GetNumBuybackItems = GetNumBuybackItems
local GetRepairAllCost = GetRepairAllCost
local RepairAllItems = RepairAllItems
local UnitExists = UnitExists
local UseContainerItem = UseContainerItem

local ceil, floor = math.ceil, math.floor
local gmatch = string.gmatch
local tinsert, tconcat, sort = table.insert, table.concat, table.sort

--------------------------------------------------------------------------------
-- game version compatibility
--------------------------------------------------------------------------------

local function getClient()
  local display_version, build_number, build_date, ui_version = GetBuildInfo()
  ui_version = ui_version or 11200
  return ui_version, display_version, build_number, build_date
end

local ui_version = getClient()
local is_tbc = false
if ui_version >= 20000 and ui_version <= 20400 then
  is_tbc = true
end

local ScrollingEdit_OnCursorChanged = _G.ScrollingEdit_OnCursorChanged
local ScrollingEdit_OnUpdate = _G.ScrollingEdit_OnUpdate

if is_tbc then
  local onCursorChanged = ScrollingEdit_OnCursorChanged
  local onUpdate = ScrollingEdit_OnUpdate
  
  ScrollingEdit_OnCursorChanged = function(self, x, y, w, h)
    onCursorChanged(x, y, w, h)
  end
  
  ScrollingEdit_OnUpdate = function(self, elapsed, scrollFrame)
    onUpdate(scrollFrame)
  end
end

--------------------------------------------------------------------------------
-- helper functions
--------------------------------------------------------------------------------
-- clear focus from any input field
local function ClearFocus()
  if GetCurrentKeyBoardFocus() then GetCurrentKeyBoardFocus():ClearFocus() end
end

-- return a money string like "2g10s83c" or "4s49c"
local function FormatMoney(amount)
  local gold = floor(amount/100/100)
  local silver = floor((amount/100)%100)
  local copper = amount%100
  local text = ""
  if gold > 0   then text = "|cffffd700"..gold.."g|r"           end
  if silver > 0 then text = text .. "|cffc7c7cf"..silver.."s|r" end
  if copper > 0 then text = text .. "|cffeda55f"..copper.."c|r" end
  return text ~= "" and text or "none"
end

--------------------------------------------------------------------------------
-- tooltip scanning
--------------------------------------------------------------------------------
-- create a scanning tooltip and references to the first few lines
local tooltipFrame = CreateFrame("GameTooltip", "AutoShopTooltip", UIParent)
local tooltipLeftLines = {}
local tooltipRightLines = {}
for i=1,5 do
  local left, right = tooltipFrame:CreateFontString(), 
    tooltipFrame:CreateFontString()
  left:SetFontObject(GameFontNormal)
  right:SetFontObject(GameFontNormal)
  tooltipFrame:AddFontStrings(left, right)
  tooltipLeftLines[i], tooltipRightLines[i] = left, right
end
tooltipFrame:SetOwner(UIParent, "ANCHOR_NONE")

-- return true if the item is both soulbound and unusable
local function IsBoundAndUnusable(bag, slot)
  tooltipFrame:ClearLines()
  tooltipFrame:SetBagItem(bag, slot)
  local r, g, b, found
  -- red text can be on the right side on lines 3 or 4, and on the left side on 
  -- line 3 to 5. If on the left, 3-4 is "Main Hand/Off Hand" text and 5 is a 
  -- class restriction. Check if unusable first since those will be much rarer 
  -- than soulbound items.
  for i=3,5 do
    -- the values are like 0.99999779462814. Also, make sure text is actually 
    -- there for the right side or else these will be old values.

    -- check right side first - if GetText() returns nil then the values are old
    if i < 5 then
      r, g, b = tooltipRightLines[i]:GetTextColor()
      -- the values are like 0.99999779462814 instead of the nice 1, 0, 0 I was 
      -- expecting
      if b < .13 and g < .13 and r > .99 and tooltipRightLines[i]:GetText() then
        found = true
      end
    end
    -- now check left side if needed - it will always have text so no need to 
    -- check for old values
    if not found then
      r, g, b = tooltipLeftLines[i]:GetTextColor()
      if b < .13 and g < .13 and r > .99 then
        found = true
      end
    end
    if found then
      -- The soulbound line can be from line 2 to the line before the red text 
      -- from above
      for j=2,i-1 do
        if tooltipLeftLines[j]:GetText() == ITEM_SOULBOUND then
          return true
        end
      end
      return nil
    end
  end
  return nil
end

-- do some final checking to see if the item should really be sold
-- the item name of the last tooltip that had a money line added to it
local tooltipMoneyName 
local tooltipMoneyAmount
tooltipFrame:SetScript("OnTooltipAddMoney", function(self, amount)
  tooltipMoneyName = tooltipLeftLines[1]:GetText()
  tooltipMoneyAmount = amount
end)
local function FinalSellChecks(bag, slot, name)
  -- it must have a sale price
  tooltipFrame:ClearLines()
  -- OnTooltipAddMoney will be used now if it has money
  tooltipFrame:SetBagItem(bag, slot) 
  if tooltipMoneyName ~= name then
    return nil
  end
  -- don't sell tabard or shirts unless they're actually on the sell list
  local text
  for i=2,4 do
    text = tooltipLeftLines[i]:GetText()
    if (text == INVTYPE_TABARD or text == INVTYPE_BODY) 
        and not AutoShopSave.autoSellList[name:lower()] then
      return nil
    end
  end
  return true
end

--------------------------------------------------------------------------------
-- handling events
--------------------------------------------------------------------------------
local eventFrame = CreateFrame("frame")
eventFrame:Hide() -- so OnUpdate won't be used

-- white quality armor and weapons used in professions and shouldn't be sold 
-- automatically
local professionItemIds = {
  [6219]  = true, -- Arclight Spanner
  [5956]  = true, -- Blacksmith Hammer
  [2901]  = true, -- Mining Pick
  [7005]  = true, -- Skinning Knife
  [6256]  = true, -- Fishing Pole
  [6365]  = true, -- Strong Fishing Pole
  [12225] = true, -- Blump Family Fishing Pole
  [6367]  = true, -- Big Iron Fishing Pole
  [6366]  = true, -- Darkwood Fishing Pole
  -- Lucky Fishing Hat - not sure this white version exists, but just in case
  [7996]  = true, 
}

-- Autosell things
local function AutoSell()
  local sell_list            = AutoShopSave.autoSellList
  local sell_gray            = AutoShopSave.autoSellGray
  local sell_white           = AutoShopSave.autoSellWhite
  local sell_green_ilvl      = AutoShopSave.autoSellGreen  
    and AutoShopSave.autoSellGreenIlvl  or 0
  local sell_blue_ilvl       = AutoShopSave.autoSellBlue   
    and AutoShopSave.autoSellBlueIlvl   or 0
  local sell_purple_ilvl     = AutoShopSave.autoSellPurple 
    and AutoShopSave.autoSellPurpleIlvl or 0
  local sell_green_unusable  = sell_green_ilvl  > 0 
    and AutoShopSave.autoSellGreenUnusable
  local sell_blue_unusable   = sell_blue_ilvl   > 0 
    and AutoShopSave.autoSellBlueUnusable
  local sell_purple_unusable = sell_purple_ilvl > 0 
    and AutoShopSave.autoSellPurpleUnusable
  local sell_recipe          = AutoShopSave.autoSellRecipe
  local use_item_destroyer   = AutoShopSave.useItemDestroyer 
    and ItemDestroyerSave

  local link, id
  -- to save how many of each item is sold instead of spamming multiple lines
  local sold_list = {} 
  local profit = 0
  local lower_name

  for bag=0,4 do
    for slot=1,GetContainerNumSlots(bag) do
      link = GetContainerItemLink(bag, slot)
      if link then
        id = tonumber(link:match(":(%d+)"))
        local name, _, quality, ilvl, _, itype = GetItemInfo(id)
        lower_name = name:lower()
        if (sell_gray and quality == 0)
          or ((itype == "Armor" or itype == "Weapon")
            and ((quality == 1 and sell_white and not professionItemIds[id])
              or (quality == 2 and (ilvl < sell_green_ilvl  
                or (sell_green_unusable  and IsBoundAndUnusable(bag, slot))))
              or (quality == 3 and (ilvl < sell_blue_ilvl   
                or (sell_blue_unusable   and IsBoundAndUnusable(bag, slot))))
              or (quality == 4 and (ilvl < sell_purple_ilvl 
                or (sell_purple_unusable and IsBoundAndUnusable(bag, slot))))))
          or (sell_recipe and itype == "Recipe" 
            and IsBoundAndUnusable(bag, slot))
          or sell_list[lower_name] then
          if not AutoShopSave.excludeList[lower_name] and 
              (not use_item_destroyer 
                  or not ItemDestroyerSave.protectedItems[lower_name]) 
                  and FinalSellChecks(bag, slot, name) then
            local _, amount = GetContainerItemInfo(bag, slot)
            sold_list[link] = sold_list[link] and sold_list[link] + amount 
              or amount
            UseContainerItem(bag, slot)
            profit = profit + tooltipMoneyAmount
          end
        end
      end
    end
  end
  if next(sold_list) ~= nil and AutoShopSave.showSellActivity then
    for link,amount in pairs(sold_list) do
      DEFAULT_CHAT_FRAME:AddMessage("Selling " 
        .. (amount > 1 and (amount .. " ") or " ") .. link)
    end
    if profit > 0 then
      DEFAULT_CHAT_FRAME:AddMessage("Selling profit: " .. FormatMoney(profit))
    end
  end
end

-- Autobuy things
local function AutoBuy()
  local buy_list = AutoShopSave.autoBuyList
  if next(buy_list) == nil then
    return
  end

  -- Items not cached by the client won't have any information yet. If the 
  -- recheck flag is set to true after seeing an unknown item, then AutoBuy() 
  -- will be tried again soon
  local recheck
  local wanted
  for i=1,GetMerchantNumItems() do
    -- name (and GetMerchantItemLink()) may not exist yet
    local name, _, _, quantity, available = GetMerchantItemInfo(i) 
    if not name then
      recheck = true
    end
    wanted = name and buy_list[name:lower()] or nil

    if wanted and available ~= 0 then
      -- if wanted is 0 then get as many as possible if it's a limited item
      local buy = wanted == 0 and (available ~= -1 and available*quantity or 0) 
        or wanted - GetItemCount(name)
      buy = AutoShopSave.hardWantedLimit and floor(buy / quantity) 
        or ceil(buy / quantity)
      if available ~= -1 and buy > available then
        buy = available
      end
      if buy > 0 then
        if AutoShopSave.showBuyActivity then
          local amount = buy * quantity
          DEFAULT_CHAT_FRAME:AddMessage("Buying " 
            .. (amount > 1 and (amount .. " ") or " ") 
            .. GetMerchantItemLink(i))
        end
        -- buy in stacks/batches in case there's not enough inventory space for 
        -- all of it
        local stack_buy = quantity > 1 and 1 or GetMerchantItemMaxStack(i)
        while buy > 0 do
          local amount = buy > stack_buy and stack_buy or buy
          BuyMerchantItem(i, amount)
          buy = buy - amount
        end
      end
    end
  end
  if recheck then
    eventFrame:Show() -- enables OnUpdate to recheck items soon
  end
end

-- unknown items won't have any information when the merchant window is first 
-- opened - this will check AutoBuy() again after waiting a second for the data 
-- to download
local recheckTime = 0
eventFrame:SetScript("OnShow", function() recheckTime = 0 end)
eventFrame:SetScript("OnUpdate", function(self, elapsed)
  recheckTime = recheckTime + elapsed
  if recheckTime >= 1 then
    self:Hide() -- stops OnUpdate
    if MerchantFrame:IsVisible() and UnitExists("npc") then
      AutoBuy() -- will restart the rechecking if still needed
    end
  end
end)

-- handle events
eventFrame:SetScript("OnEvent", function()
  -- check if an item needs to be bought back
  if event == "MERCHANT_UPDATE" then
    local excluded = AutoShopSave.excludeList
    local name
    local use_item_destroyer = AutoShopSave.useItemDestroyer 
      and ItemDestroyerSave
    for i=1,GetNumBuybackItems() do
      name = (GetBuybackItemInfo(i))
      name = name and name:lower()
      if name and (excluded[name] or (use_item_destroyer and 
          ItemDestroyerSave.protectedItems[name])) then
        DEFAULT_CHAT_FRAME:AddMessage("AutoShop: Buying back protected item: " 
          .. GetBuybackItemLink(i), 1, 0, 0)
        BuybackItem(i)
      end
    end
    return
  end

  -- react to the shop window opening
  if event == "MERCHANT_SHOW" then
    AutoSell()
    AutoBuy()
    if CanMerchantRepair() and AutoShopSave.autoRepair then
      local cost, can_repair = GetRepairAllCost()
      if can_repair and GetMoney() >= cost then
        if AutoShopSave.autoRepairGuild then
          RepairAllItems(1)
        end
        RepairAllItems()
        DEFAULT_CHAT_FRAME:AddMessage("Repair cost: " .. FormatMoney(cost))
      end
    end
    return
  end

  -- set up default settings if needed
  if event == "ADDON_LOADED" and arg1 == "AutoShop" then
    eventFrame:UnregisterEvent(event)
    if _G.AutoShopSave                     == nil then _G.AutoShopSave                     = {}    end
    if AutoShopSave.autoSellGray           == nil then AutoShopSave.autoSellGray           = false end
    if AutoShopSave.autoSellWhite          == nil then AutoShopSave.autoSellWhite          = false end
    if AutoShopSave.autoSellGreen          == nil then AutoShopSave.autoSellGreen          = false end
    if AutoShopSave.autoSellGreenIlvl      == nil then AutoShopSave.autoSellGreenIlvl      = 79    end
    if AutoShopSave.autoSellGreenUnusable  == nil then AutoShopSave.autoSellGreenUnusable  = false end
    if AutoShopSave.autoSellBlue           == nil then AutoShopSave.autoSellBlue           = false end
    if AutoShopSave.autoSellBlueIlvl       == nil then AutoShopSave.autoSellBlueIlvl       = 71    end
    if AutoShopSave.autoSellBlueUnusable   == nil then AutoShopSave.autoSellBlueUnusable   = false end
    if AutoShopSave.autoSellPurple         == nil then AutoShopSave.autoSellPurple         = false end
    if AutoShopSave.autoSellPurpleIlvl     == nil then AutoShopSave.autoSellPurpleIlvl     = 95    end
    if AutoShopSave.autoSellPurpleUnusable == nil then AutoShopSave.autoSellPurpleUnusable = false end
    if AutoShopSave.autoSellRecipe         == nil then AutoShopSave.autoSellRecipe         = false end
    if AutoShopSave.hardWantedLimit        == nil then AutoShopSave.hardWantedLimit        = false end
    if AutoShopSave.showBuyActivity        == nil then AutoShopSave.showBuyActivity        = true  end
    if AutoShopSave.showSellActivity       == nil then AutoShopSave.showSellActivity       = true  end
    if AutoShopSave.protectExcluded        == nil then AutoShopSave.protectExcluded        = false end
    if AutoShopSave.autoRepair             == nil then AutoShopSave.autoRepair             = false end
    if AutoShopSave.autoRepairGuild        == nil then AutoShopSave.autoRepairGuild        = false end
    if AutoShopSave.useItemDestroyer       == nil then AutoShopSave.useItemDestroyer       = false end
    if AutoShopSave.autoSellList           == nil then AutoShopSave.autoSellList           = {}    end
    if AutoShopSave.excludeList            == nil then AutoShopSave.excludeList            = {}    end
    if AutoShopSave.autoBuyList            == nil then AutoShopSave.autoBuyList            = {}    end

    if AutoShopSave.protectExcluded then
      -- to check buy back for protected items
      eventFrame:RegisterEvent("MERCHANT_UPDATE") 
    end
    return
  end
end)
-- temporary - to set up default settings if needed
eventFrame:RegisterEvent("ADDON_LOADED")  
-- to know when a shop window has opened
eventFrame:RegisterEvent("MERCHANT_SHOW") 

--------------------------------------------------------------------------------
-- options window
--------------------------------------------------------------------------------
local guiFrame = nil -- created on first use
local function CreateGUI()
  if guiFrame then
    return
  end

  guiFrame = CreateFrame("Frame", "AutoShopFrame", UIParent)
  -- make it closable with escape key
  tinsert(UISpecialFrames, guiFrame:GetName()) 
  guiFrame:SetFrameStrata("HIGH")
  guiFrame:SetBackdrop({
    bgFile="Interface/Tooltips/UI-Tooltip-Background",
    edgeFile="Interface/DialogFrame/UI-DialogBox-Border",
    tile=1, tileSize=32, edgeSize=32,
    insets={left=11, right=12, top=12, bottom=11}
  })
  guiFrame:SetBackdropColor(0,0,0,1)
  guiFrame:SetPoint("CENTER")
  -- left/right edges + 3 editboxes and space between 2 of them
  guiFrame:SetWidth(32+(242*2)+240) 
  guiFrame:SetHeight(450)
  guiFrame:SetMovable(true)
  guiFrame:EnableMouse(true)
  guiFrame:RegisterForDrag("LeftButton")
  guiFrame:SetScript("OnDragStart", guiFrame.StartMoving)
  guiFrame:SetScript("OnDragStop", guiFrame.StopMovingOrSizing)
  guiFrame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and not self.isMoving then
      self:StartMoving()
      self.isMoving = true
    end
  end)
  guiFrame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" and self.isMoving then
      self:StopMovingOrSizing()
      self.isMoving = false
    end
  end)
  guiFrame:SetScript("OnHide", function(self)
    if self.isMoving then
      self:StopMovingOrSizing()
      self.isMoving = false
    end
  end)
  guiFrame:Hide()

  --------------------------------------------------
  -- header title
  --------------------------------------------------
  local textureHeader = guiFrame:CreateTexture(nil, "ARTWORK")
  textureHeader:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
  textureHeader:SetWidth(315)
  textureHeader:SetHeight(64)
  textureHeader:SetPoint("TOP", 0, 12)
  local textHeader = guiFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  textHeader:SetPoint("TOP", textureHeader, "TOP", 0, -14)
  textHeader:SetText("AutoShop 1.0")

  --------------------------------------------------
  -- checkbox options
  --------------------------------------------------
  -- create a checkbox and fix the hit detection on it
  local function CreateCheckbox(name, text, tooltip)
    local frame = CreateFrame("CheckButton", "AutoshopCheckbox"..name, guiFrame, 
      "OptionsCheckButtonTemplate")
    local fontstring = _G[frame:GetName().."Text"]
    fontstring:SetFontObject(GameFontNormalSmall)
    fontstring:SetText(text)
    local width = fontstring:GetStringWidth()
    frame:SetHitRectInsets(0, -width, 4, 4)
    frame.tooltipText = tooltip
    return frame
  end

  -- Autosell gray items
  local checkboxAutoSellGray = CreateCheckbox("AutoSellGray", 
    "Sell gray quality items.")
  checkboxAutoSellGray:SetPoint("TOPLEFT", guiFrame, "TOPLEFT", 12, -28)
  checkboxAutoSellGray:SetScript("OnClick", function()
    ClearFocus()
    AutoShopSave.autoSellGray = this:GetChecked() or false
  end)

  -- Autosell white equipment
  local checkboxAutoSellWhite = CreateCheckbox("AutoSellWhite", 
    "Sell white equipment except profession tools.",
    "Only sells armor and weapons (but not shirts and tabards) -"
      .. " the excluded tools are like blacksmith hammers and fishing poles.")
  checkboxAutoSellWhite:SetPoint("TOPLEFT", checkboxAutoSellGray, "BOTTOMLEFT", 
    0, 6)
  checkboxAutoSellWhite:SetScript("OnClick", function()
    ClearFocus()
    AutoShopSave.autoSellWhite = this:GetChecked() or false
  end)

  -- Autosell green/blue/purple equipment
  local function CreateQualityOption(color, widget_above_this)
    -- checkbox to enable the option
    local checkbox1 = CreateCheckbox("AutoSell"..color, "Sell " .. color:lower() 
      .. " equipment below ilvl")
    checkbox1:SetPoint("TOPLEFT", widget_above_this, "BOTTOMLEFT", 0, 6)
    checkbox1:SetScript("OnClick", function()
      ClearFocus()
      AutoShopSave["autoSell"..color] = this:GetChecked() or false
    end)

    -- input to set the ilvl
    local input = CreateFrame("EditBox", "AutoshopInputAutoSell"..color, 
      guiFrame, "InputBoxTemplate")
    input:SetWidth(28)
    input:SetHeight(16)
    input:SetNumeric(true)
    input:SetMaxLetters(3)
    input:SetPoint("LEFT", _G[checkbox1:GetName().."Text"], "RIGHT", 8, 0)
    input:SetAutoFocus(false)
    input:SetScript("OnEnterPressed", function() this:ClearFocus() end)
    input:SetScript("OnEditFocusLost", function()
      AutoShopSave["autoSell"..color.."Ilvl"] = tonumber(this:GetText()) or 0
      input:SetText(AutoShopSave["autoSell"..color.."Ilvl"])
    end)

    -- checkbox to also sell soulbound/unusable equipment no matter what the 
    -- ilvl is
    local checkbox2 = CreateFrame("CheckButton", 
      "AutoshopCheckboxUnusable"..color, guiFrame, "OptionsCheckButtonTemplate")
    checkbox2:SetPoint("LEFT", input, "RIGHT", 0, 0)
    
    local fontstring = _G[checkbox2:GetName().."Text"]
    fontstring:SetFontObject(GameFontNormalSmall)
    fontstring:SetText("or unusable & bound.")
    
    checkbox2.tooltipText = "It only counts as unusable from incompatible wear"
      .. " types (like plate or wand) or class restrictions."
    checkbox2:SetScript("OnClick", function()
      ClearFocus()
      AutoShopSave["autoSell"..color.."Unusable"] = this:GetChecked() or false
    end)

    return checkbox1, input, checkbox2
  end
  local checkboxAutoSellGreen,  inputGreenIlvl,  checkboxAutoSellGreenUnusable  
    = CreateQualityOption("Green",  checkboxAutoSellWhite)
  local checkboxAutoSellBlue,   inputBlueIlvl,   checkboxAutoSellBlueUnusable   
    = CreateQualityOption("Blue",   checkboxAutoSellGreen)
  local checkboxAutoSellPurple, inputPurpleIlvl, checkboxAutoSellPurpleUnusable 
    = CreateQualityOption("Purple", checkboxAutoSellBlue)
  checkboxAutoSellGreen.tooltipText  = "Only sells armor and weapons"
    .. " (but not shirts and tabards) -"
    .. " 79 may be the lowest green ilvl to disenchant into TBC mats."
  checkboxAutoSellBlue.tooltipText   = "Only sells armor and weapons"
    .. " (but not shirts and tabards) -"
    .. " 71 may be the lowest blue ilvl to disenchant into TBC mats."
  checkboxAutoSellPurple.tooltipText = "Only sells armor and weapons"
    .. " (but not shirts and tabards) -"
    .. " 95 may be the lowest purple ilvl to disenchant into TBC mats."

  -- Autosell recipes
  local checkboxAutoSellRecipe = CreateCheckbox(
    "AutoSellRecipe", "Sell recipes that are both unusable & bound.",
    "|cffff0000Warning: this includes recipes you don't have a high enough"
      .. " skill for, so you may want to wait until 375 to enable this.|r")
  checkboxAutoSellRecipe:SetPoint("TOPLEFT", checkboxAutoSellPurple, 
    "BOTTOMLEFT", 0, 6)
  checkboxAutoSellRecipe:SetScript("OnClick", function()
    ClearFocus()
    AutoShopSave.autoSellRecipe = this:GetChecked() or false
  end)

  -- Hard wanted amount limit
  local checkboxHardLimit = CreateCheckbox("HardLimit", 
    "Don't buy over the wanted amount with batches.",
    "For example, it won't buy 5x water if only 3 more are wanted.")
  checkboxHardLimit:SetPoint("TOPLEFT", checkboxAutoSellGray, "TOPLEFT", 
    guiFrame:GetWidth()/2+24, 0)
  checkboxHardLimit:SetScript("OnClick", function()
    ClearFocus()
    AutoShopSave.hardWantedLimit = this:GetChecked() or false
  end)

  -- buy back protected items
  local checkboxProtectExcluded = CreateCheckbox("ProtectExcluded", 
    'Buy back items in the "sell exclusions" list.',
    "This is to protect against manual accidental selling.")
  checkboxProtectExcluded:SetPoint("TOPLEFT", checkboxHardLimit, "BOTTOMLEFT", 
    0, 6)
  checkboxProtectExcluded:SetScript("OnClick", function()
    ClearFocus()
    AutoShopSave.protectExcluded = this:GetChecked() or false
    if AutoShopSave.protectExcluded then
      eventFrame:RegisterEvent("MERCHANT_UPDATE")
    else
      eventFrame:UnregisterEvent("MERCHANT_UPDATE")
    end
  end)

  -- repair items
  local checkboxAutoRepair = CreateCheckbox("AutoRepair", 
    "Repair automatically")
  checkboxAutoRepair:SetPoint("TOPLEFT", checkboxProtectExcluded, "BOTTOMLEFT", 
    0, 6)
  checkboxAutoRepair:SetScript("OnClick", function()
    ClearFocus()
    AutoShopSave.autoRepair = this:GetChecked() or false
  end)

  local checkboxAutoRepairGuild = CreateCheckbox("AutoRepairGuild", 
    "and try using guild money.")
  checkboxAutoRepairGuild:SetPoint("LEFT", 
    _G[checkboxAutoRepair:GetName().."Text"], "RIGHT", 0, 0)
  checkboxAutoRepairGuild:SetScript("OnClick", function()
    ClearFocus()
    AutoShopSave.autoRepairGuild = this:GetChecked() or false
  end)

  -- show buy activity
  local checkboxShowBuyActivity = CreateCheckbox("ShowBuyActivity", 
    "Show chat window messages about buying items.")
  checkboxShowBuyActivity:SetPoint("TOPLEFT", checkboxAutoRepair, "BOTTOMLEFT", 
    0, 6)
  checkboxShowBuyActivity:SetScript("OnClick", function()
    ClearFocus()
    AutoShopSave.showBuyActivity = this:GetChecked() or false
  end)

  -- show sell activity
  local checkboxShowSellActivity = CreateCheckbox("ShowSellActivity", 
    "Show chat window messages about selling items.")
  checkboxShowSellActivity:SetPoint("TOPLEFT", checkboxShowBuyActivity, 
    "BOTTOMLEFT", 0, 6)
  checkboxShowSellActivity:SetScript("OnClick", function()
    ClearFocus()
    AutoShopSave.showSellActivity = this:GetChecked() or false
  end)

  -- use ItemDestroyer list
  local checkboxUseItemDestroyer = nil -- only created if ItemDestroyer exists
  if ItemDestroyerSave then
    checkboxUseItemDestroyer = CreateCheckbox("UseItemDestroyer", 
      "Add ItemDestroyer's protection list to sell exclusions.",
      "They won't be visually added here, but when the sell exclusion list is"
        .. " checked for something then ItemDestroyer's list will be too.")
    checkboxUseItemDestroyer:SetPoint("TOPLEFT", checkboxShowSellActivity, 
      "BOTTOMLEFT", 0, 6)
    checkboxUseItemDestroyer:SetScript("OnClick", function()
      ClearFocus()
      AutoShopSave.useItemDestroyer = this:GetChecked() or false
    end)
  end

  --------------------------------------------------
  -- bottom help text
  --------------------------------------------------
  local textTips = guiFrame:CreateFontString(nil, "ARTWORK", 
    "GameFontNormalSmall")
  textTips:SetPoint("BOTTOM", guiFrame, "BOTTOM", 0, 13)
  textTips:SetText("You can drag items to the lists."
    .. " To buy all of a limited quantity item, don't put a wanted amount.")

  --------------------------------------------------
  -- editboxes
  --------------------------------------------------
  local function CreateEditBox(type_name, position_number, title_left, 
      title_right)
    local container = CreateFrame("Frame", "AutoshopEdit"..type_name, guiFrame)
    local input = CreateFrame("EditBox", "AutoshopEdit"..type_name.."Input", 
      container)
    local scroll = CreateFrame("ScrollFrame", 
      "AutoshopEdit"..type_name.."Scroll", container, 
      "UIPanelScrollFrameTemplate")

    -- header title (left)
    local title1 = guiFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title1:SetPoint("LEFT", guiFrame, "LEFT", 16 + ((position_number-1) * 242), 
      0)
    title1:SetPoint("TOP", checkboxAutoSellRecipe, "BOTTOM", 0, -18)
    title1:SetText(title_left)

    -- editbox container
    container:SetPoint("TOPLEFT", title1, "BOTTOMLEFT", 0, -2)
    container:SetPoint("BOTTOM", textTips, "TOP", 0, 0)
    container:SetWidth(220)
    container:SetBackdrop({
      bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
      tile=1, tileSize=32, edgeSize=16,
      insets={left=5, right=5, top=5, bottom=5}})
    container:SetBackdropColor(0,0,0,1)

    -- header title (right)
    if title_right then
      local title2 = guiFrame:CreateFontString(nil, "ARTWORK", 
        "GameFontNormalSmall")
      title2:SetPoint("TOP", title1, "TOP", 0, 0)
      title2:SetPoint("RIGHT", container, "RIGHT", 0, 0)
      title2:SetText(title_right)
    end

    -- input part
    input:SetMultiLine(true)
    input:SetAutoFocus(false)
    input:EnableMouse(true)
    input:SetFont("Fonts/ARIALN.ttf", 14)
    input:SetWidth(container:GetWidth()-20)
    input:SetHeight(container:GetHeight()-8)
    input:SetScript("OnEscapePressed", function() input:ClearFocus() end)

    -- scroll part
    scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -6, 8)
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() input:SetFocus() end)
    scroll:SetScrollChild(input)

    -- taken from Blizzard's macro UI XML to handle scrolling
    input:SetScript("OnTextChanged", function()
      local scrollbar = _G[scroll:GetName() .. "ScrollBar"]
      local min, max = scrollbar:GetMinMaxValues()
      if max > 0 and this.max ~= max then
        this.max = max
        scrollbar:SetValue(max)
      end
    end)
    input:SetScript("OnUpdate", function(self)
      local self = self or this
      ScrollingEdit_OnUpdate(self, arg1, scroll)
    end)
    input:SetScript("OnCursorChanged", function(self)
      local self = self or this
      ScrollingEdit_OnCursorChanged(self, arg1, arg2, arg3, arg4)
    end)

    -- allow items to be dragged into the lists
    local function InputReceiveItem(input)
      local cursor_type, _, cursor_link = GetCursorInfo()
      if cursor_type == "item" and input:IsVisible() then
        local name = cursor_link:match("%[(.+)]"):lower()
        local original = input:GetText()
        if original == "" or original:sub(-1) == "\n" then
          input:SetText(original .. name .. "\n")
        else
          input:SetText(original .. "\n" .. name .. "\n")
        end
        input:SetFocus()
        CloseDropDownMenus()
        ClearCursor()
      end
    end

    local function SetReceivable(widget, input)
      widget:SetScript("OnReceiveDrag", function() InputReceiveItem(input) end)
      widget.OnMouseDownOriginal = widget:GetScript("OnMouseDown")
      widget:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then InputReceiveItem(input) end
        if self.OnMouseDownOriginal then
          self:OnMouseDownOriginal(button)
        end
      end)
    end

    -- has to affect the scroll part too to cover all areas
    SetReceivable(scroll, input) 
    SetReceivable(input, input)
    return input
  end

  local inputSell    = CreateEditBox("Sell", 1, "Sell:")
  local inputExclude = CreateEditBox("Exclude", 2, "Sell exclusions:")
  local inputBuy     = CreateEditBox("Buy", 3, "Buy:", 
    "(example: 60 Wild Quillvine)")

  -- saving the lists
  inputSell:SetScript("OnEditFocusLost", function()
    AutoShopSave.autoSellList = {}
    for line in gmatch(this:GetText(), "[^\r\n]+") do
      AutoShopSave.autoSellList[line:trim():lower()] = true
    end
  end)

  inputExclude:SetScript("OnEditFocusLost", function()
    AutoShopSave.excludeList = {}
    for line in gmatch(this:GetText(), "[^\r\n]+") do
      AutoShopSave.excludeList[line:trim():lower()] = true
    end
  end)

  inputBuy:SetScript("OnEditFocusLost", function()
    AutoShopSave.autoBuyList = {}
    for line in gmatch(this:GetText(), "[^\r\n]+") do
      local amount, name = line:match("^%s*(%d*)%s*(.+)")
      AutoShopSave.autoBuyList[name:trim():lower()] = amount == "" and 0 
        or tonumber(amount)
    end
  end)

  --------------------------------------------------
  -- close button
  --------------------------------------------------
  local buttonClose = CreateFrame("Button", "AutoshopButtonClose", guiFrame, 
    "UIPanelCloseButton")
  buttonClose:SetPoint("TOPRIGHT", guiFrame, "TOPRIGHT", -8, -8)
  buttonClose:SetScript("OnClick", function()
    ClearFocus()
    guiFrame:Hide()
  end)

  --------------------------------------------------
  -- showing the window
  --------------------------------------------------
  guiFrame:SetScript("OnShow", function()
    checkboxAutoSellGray:SetChecked(AutoShopSave.autoSellGray)
    checkboxAutoSellWhite:SetChecked(AutoShopSave.autoSellWhite)
    checkboxAutoSellGreen:SetChecked(AutoShopSave.autoSellGreen)
    checkboxAutoSellGreenUnusable:SetChecked(AutoShopSave.autoSellGreenUnusable)
    checkboxAutoSellBlue:SetChecked(AutoShopSave.autoSellBlue)
    checkboxAutoSellBlueUnusable:SetChecked(AutoShopSave.autoSellBlueUnusable)
    checkboxAutoSellPurple:SetChecked(AutoShopSave.autoSellPurple)
    checkboxAutoSellPurpleUnusable:SetChecked(
      AutoShopSave.autoSellPurpleUnusable)
    checkboxAutoSellRecipe:SetChecked(AutoShopSave.autoSellRecipe)

    checkboxHardLimit:SetChecked(AutoShopSave.hardWantedLimit)
    checkboxShowBuyActivity:SetChecked(AutoShopSave.showBuyActivity)
    checkboxShowSellActivity:SetChecked(AutoShopSave.showSellActivity)
    checkboxProtectExcluded:SetChecked(AutoShopSave.protectExcluded)
    checkboxAutoRepair:SetChecked(AutoShopSave.autoRepair)
    checkboxAutoRepairGuild:SetChecked(AutoShopSave.autoRepairGuild)
    if checkboxUseItemDestroyer then
      checkboxUseItemDestroyer:SetChecked(AutoShopSave.useItemDestroyer)
    end

    inputGreenIlvl:SetText(AutoShopSave.autoSellGreenIlvl)
    inputBlueIlvl:SetText(AutoShopSave.autoSellBlueIlvl)
    inputPurpleIlvl:SetText(AutoShopSave.autoSellPurpleIlvl)

    -- put lists in alphabetical order
    local list = {}
    for name in pairs(AutoShopSave.autoSellList) do
      tinsert(list, name)
    end
    sort(list)
    inputSell:SetText(tconcat(list, "\n"))

    list = {}
    for name in pairs(AutoShopSave.excludeList) do
      tinsert(list, name)
    end
    sort(list)
    inputExclude:SetText(tconcat(list, "\n"))

    list = {}
    for name,amount in pairs(AutoShopSave.autoBuyList) do
      if amount and amount > 0 then
        tinsert(list, amount .. " " .. name)
      else
        tinsert(list, name)
      end
    end
    sort(list, function(text1, text2)
      return text1:match("^%d*%s*(.+)") < text2:match("^%d*%s*(.+)") 
    end)
    inputBuy:SetText(tconcat(list, "\n"))
  end)

  return
end

--------------------------------------------------------------------------------
-- slash command to open the options window
--------------------------------------------------------------------------------
_G.SLASH_AUTOSHOP1 = "/autoshop"
_G.SLASH_AUTOSHOP2 = "/as"
function SlashCmdList.AUTOSHOP()
  if not guiFrame then
    CreateGUI()
  end
  guiFrame:Show()
end
