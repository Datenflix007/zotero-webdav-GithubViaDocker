var MyLiteratureVault;

function log(message) {
  Zotero.debug("MyLiteratureVault: " + message);
}

function install() {
  log("Installed");
}

async function startup({ id, version, rootURI }) {
  log("Starting");
  MyLiteratureVault = {
    id,
    version,
    rootURI,
    elementIDs: [],

    addToWindow(window) {
      if (!window.ZoteroPane) return;
      const doc = window.document;
      if (doc.getElementById("myliteraturevault-open-ui")) return;

      const menuItem = doc.createXULElement("menuitem");
      menuItem.id = "myliteraturevault-open-ui";
      menuItem.setAttribute("label", "MyLiteratureVault öffnen");
      menuItem.addEventListener("command", () => this.openUi(window));

      const menu = doc.getElementById("menu_viewPopup") || doc.getElementById("menu_ToolsPopup");
      if (menu) {
        menu.appendChild(menuItem);
        this.elementIDs.push(menuItem.id);
      }
    },

    addToAllWindows() {
      for (const win of Zotero.getMainWindows()) {
        this.addToWindow(win);
      }
    },

    removeFromWindow(window) {
      const doc = window.document;
      for (const id of this.elementIDs) {
        doc.getElementById(id)?.remove();
      }
    },

    removeFromAllWindows() {
      for (const win of Zotero.getMainWindows()) {
        this.removeFromWindow(win);
      }
    },

    openUi(window) {
      window.openDialog(
        this.rootURI + "vault.xhtml",
        "myliteraturevault-ui",
        "chrome,resizable,centerscreen,width=1200,height=800"
      );
    }
  };

  MyLiteratureVault.addToAllWindows();
}

function onMainWindowLoad({ window }) {
  MyLiteratureVault?.addToWindow(window);
}

function onMainWindowUnload({ window }) {
  MyLiteratureVault?.removeFromWindow(window);
}

function shutdown() {
  log("Shutting down");
  MyLiteratureVault?.removeFromAllWindows();
  MyLiteratureVault = undefined;
}

function uninstall() {
  log("Uninstalled");
}
