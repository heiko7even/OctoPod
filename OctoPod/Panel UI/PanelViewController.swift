import UIKit

class PanelViewController: UIViewController, UIPopoverPresentationControllerDelegate, OctoPrintClientDelegate, OctoPrintSettingsDelegate, AppConfigurationDelegate, CameraViewDelegate, WatchSessionManagerDelegate {
    
    private static let CONNECT_CONFIRMATION = "PANEL_CONNECT_CONFIRMATION"

    let printerManager: PrinterManager = { return (UIApplication.shared.delegate as! AppDelegate).printerManager! }()
    let octoprintClient: OctoPrintClient = { return (UIApplication.shared.delegate as! AppDelegate).octoprintClient }()
    let appConfiguration: AppConfiguration = { return (UIApplication.shared.delegate as! AppDelegate).appConfiguration }()
    let watchSessionManager: WatchSessionManager = { return (UIApplication.shared.delegate as! AppDelegate).watchSessionManager }()

    var printerConnected: Bool?

    @IBOutlet weak var printerSelectButton: UIBarButtonItem!
    @IBOutlet weak var connectButton: UIBarButtonItem!
    
    @IBOutlet weak var notRefreshingButton: UIButton!
    var notRefreshingReason: String?
    
    var camerasViewController: CamerasViewController?
    var subpanelsViewController: SubpanelsViewController?
    @IBOutlet weak var subpanelsView: UIView!
    
    var screenHeight: CGFloat!
    var imageAspectRatio16_9: Bool = false
    var transitioningNewPage: Bool = false
    var camera4_3HeightConstraintPortrait: CGFloat! = 313
    var camera4_3HeightConstraintLandscape: CGFloat! = 330
    var camera16_9HeightConstraintPortrait: CGFloat! = 313
    var cameral16_9HeightConstraintLandscape: CGFloat! = 330

    var uiOrientationBeforeFullScreen: UIInterfaceOrientation?
    @IBOutlet weak var cameraHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var cameraBottomConstraint: NSLayoutConstraint!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Keep track of children controllers
        trackChildrenControllers()
        
        // Add a gesture recognizer to camera view so we can handle taps
        camerasViewController?.embeddedCameraTappedCallback = {() in
            self.handleEmbeddedCameraTap()
        }
        
        // Listen to event when first image gets loaded so we can adjust UI based on aspect ratio of image
        camerasViewController?.embeddedCameraDelegate = self
        
        // Indicate that we want to instruct users that gestures can be used to manipulate image
        // Messages will not be visible after user used these features
        camerasViewController?.infoGesturesAvailable = true

        // Listen to events when app comes back from background
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        
        // Listen to events coming from OctoPrintClient
        octoprintClient.delegates.append(self)
        
        // Calculate constraint for subpanel
        calculateCameraHeightConstraints()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        // Listen to changes to OctoPrint Settings in case the camera orientation has changed
        octoprintClient.octoPrintSettingsDelegates.append(self)
        // Listen to changes when app is locked or unlocked
        appConfiguration.delegates.append(self)
        // Listen to changes coming from Apple Watch
        watchSessionManager.delegates.append(self)
        // Set background color to the view
        let theme = Theme.currentTheme()
        view.backgroundColor = theme.backgroundColor()

        // Show default printer
        showDefaultPrinter()
        // Configure UI based on app locked state
        configureBasedOnAppLockedState()
        // Enable or disable printer select button depending on number of printers configured
        printerSelectButton.isEnabled = printerManager.getPrinters().count > 1
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        // Stop listening to changes to OctoPrint Settings
        octoprintClient.remove(octoPrintSettingsDelegate: self)
        // Stop listening to changes when app is locked or unlocked
        appConfiguration.remove(appConfigurationDelegate: self)
        // Stop listening to changes coming from Apple Watch
        watchSessionManager.remove(watchSessionManagerDelegate: self)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    // MARK: - Connect / Disconnect

    @IBAction func toggleConnection(_ sender: Any) {
        if printerConnected! {
            // Define connect logic that will be reused in 2 places. Variable to prevent copy/paste
            let disconnect = {
                self.octoprintClient.disconnectFromPrinter { (requested: Bool, error: Error?, response: HTTPURLResponse) in
                    if requested {
                        self.subpanelsViewController?.printerSelectedChanged()
                    } else {
                        self.handleConnectionError(error: error, response: response)
                    }
                }
            }
            if appConfiguration.confirmationOnDisconnect() {
                // Prompt for confirmation that we want to disconnect from printer
                showConfirm(message: NSLocalizedString("Confirm disconnect", comment: ""), yes: { (UIAlertAction) -> Void in
                    disconnect()
                }, no: { (UIAlertAction) -> Void in
                    // Do nothing
                })
            } else {
                // Disconnect with no prompt to user
                disconnect()
            }
        } else {
            // Define connect logic that will be reused in 2 places. Variable to prevent copy/paste
            let connect = {
                self.octoprintClient.connectToPrinter { (requested: Bool, error: Error?, response: HTTPURLResponse) in
                    if requested {
                        self.subpanelsViewController?.printerSelectedChanged()
                    } else {
                        self.handleConnectionError(error: error, response: response)
                    }
                }
            }
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: PanelViewController.CONNECT_CONFIRMATION) && !appConfiguration.confirmationOnConnect() {
                // Confirmation was accepted and user does not want to be prompted each time so just connect
                connect()
            } else {
                // Prompt for confirmation so users know that if printing then print will be lost
                showConfirm(message: NSLocalizedString("Confirm connect", comment: ""), yes: { (UIAlertAction) -> Void in
                    // Mark that user accepted. Prompt will not appear again if user does not want a prompt each time (this is default case)
                    defaults.set(true, forKey: PanelViewController.CONNECT_CONFIRMATION)
                    // Connect now
                    connect()
                }, no: { (UIAlertAction) -> Void in
                    // Do nothing
                })
            }
        }
    }
    
    // MARK: - Navigation
    
    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "select_camera_popover", let controller = segue.destination as? SelectDefaultPrinterViewController {
            controller.popoverPresentationController!.delegate = self
            // Refresh based on new default printer
            controller.onCompletion = {
                self.refreshNewSelectedPrinter()
            }
        }
        
        if segue.identifier == "connection_error_details", let controller = segue.destination as? NotRefreshingReasonViewController {
            controller.popoverPresentationController!.delegate = self
            // Make the popover appear at the middle of the button
            segue.destination.popoverPresentationController!.sourceRect = CGRect(x: notRefreshingButton.frame.size.width/2, y: 0 , width: 0, height: 0)
            if let reason = notRefreshingReason {
                controller.reason = reason
            } else {
                controller.reason = NSLocalizedString("Unknown", comment: "")
            }
        }
    }
    
    // MARK: - Unwind operations

    @IBAction func backFromSetTemperature(_ sender: UIStoryboardSegue) {
        if let controller = sender.source as? SetTargetTempViewController, let text = controller.targetTempField.text, let newTarget: Int = Int(text) {
            switch controller.targetTempScope! {
            case SetTargetTempViewController.TargetScope.bed:
                octoprintClient.bedTargetTemperature(newTarget: newTarget) { (requested: Bool, error: Error?, response: HTTPURLResponse) in
                    // TODO Handle error
                }
                // Donate intent so user can create convenient Siri shortcuts
                if let printer = printerManager.getPrinterByName(name: self.navigationItem.title ?? "_") {
                    IntentsDonations.donateBedTemp(printer: printer, temperature: newTarget)
                }
            case SetTargetTempViewController.TargetScope.tool0:
                octoprintClient.toolTargetTemperature(toolNumber: 0, newTarget: newTarget) { (requested: Bool, error: Error?, response: HTTPURLResponse) in
                    // TODO Handle error
                }
                // Donate intent so user can create convenient Siri shortcuts
                if let printer = printerManager.getPrinterByName(name: self.navigationItem.title ?? "_") {
                    IntentsDonations.donateToolTemp(printer: printer, tool: 0, temperature: newTarget)
                }
            case SetTargetTempViewController.TargetScope.tool1:
                octoprintClient.toolTargetTemperature(toolNumber: 1, newTarget: newTarget) { (requested: Bool, error: Error?, response: HTTPURLResponse) in
                    // TODO Handle error
                }
                // Donate intent so user can create convenient Siri shortcuts
                if let printer = printerManager.getPrinterByName(name: self.navigationItem.title ?? "_") {
                    IntentsDonations.donateToolTemp(printer: printer, tool: 1, temperature: newTarget)
                }
            }
        }
    }

    @IBAction func backFromFailedJobRequest(_ sender: UIStoryboardSegue) {
        if let controller = sender.source as? JobInfoViewController, let jobOperation = controller.requestedJobOperation {
            switch jobOperation {
            case .cancel:
                showAlert(NSLocalizedString("Job", comment: ""), message: NSLocalizedString("Notify failed cancel job", comment: ""))
            case .pause:
                showAlert(NSLocalizedString("Job", comment: ""), message: NSLocalizedString("Notify failed pause job", comment: ""))
            case .resume:
                showAlert(NSLocalizedString("Job", comment: ""), message: NSLocalizedString("Notify failed resume job", comment: ""))
            case .restart:
                showAlert(NSLocalizedString("Job", comment: ""), message: NSLocalizedString("Notify failed restart job", comment: ""))
            case .reprint:
                showAlert(NSLocalizedString("Job", comment: ""), message: NSLocalizedString("Notify failed print job again", comment: ""))
            }
        }
    }

    // MARK: - UIPopoverPresentationControllerDelegate
    
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        return UIModalPresentationStyle.none
    }

    // We need to add this so it works on iPhone plus in landscape mode
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return UIModalPresentationStyle.none
    }
    
    // MARK: - OctoPrintClientDelegate
    
    // Notification that OctoPrint state has changed. This may include printer status information
    func printerStateUpdated(event: CurrentStateEvent) {
        if let closed = event.closedOrError {
            updateConnectButton(printerConnected: !closed)
        }
        subpanelsViewController?.currentStateUpdated(event: event)
    }

    // Notification sent when websockets got connected
    func websocketConnected() {
        DispatchQueue.main.async {
            self.notRefreshingReason = nil
            self.notRefreshingButton.isHidden = true
        }
    }

    // Notification sent when websockets got disconnected due to an error (or failed to connect)
    func websocketConnectionFailed(error: Error) {
        DispatchQueue.main.async {
            self.notRefreshingReason = self.obtainConnectionErrorReason(error: error)
            self.notRefreshingButton.isHidden = false
        }
    }
    
    // Notification that we are about to connect to OctoPrint server
    func notificationAboutToConnectToServer() {
        // Assume printer is not connected
        updateConnectButton(printerConnected: false)
        DispatchQueue.main.async {
            // Clear any error message
            self.notRefreshingReason = nil
            self.notRefreshingButton.isHidden = true
        }
    }

    // Notification that HTTP request failed (connection error, authentication error or unexpect http status code)
    func handleConnectionError(error: Error?, response: HTTPURLResponse) {
        if let nsError = error as NSError?, let url = response.url {
            if nsError.code == Int(CFNetworkErrors.cfurlErrorTimedOut.rawValue) && url.host == "octopi.local" {
                self.showAlert(NSLocalizedString("Connection failed", comment: ""), message: NSLocalizedString("Cannot reach 'octopi.local' over mobile network or service is down", comment: ""))
            } else if nsError.code == Int(CFNetworkErrors.cfurlErrorTimedOut.rawValue) {
                self.showAlert(NSLocalizedString("Connection failed", comment: ""), message: NSLocalizedString("Service is down or incorrect port", comment: ""))
            } else if nsError.code == Int(CFNetworkErrors.cfurlErrorCancelled.rawValue) {
                // We ask authentication to be cancelled when when creds are bad
                self.showAlert(NSLocalizedString("Authentication failed", comment: ""), message: NSLocalizedString("Incorrect authentication credentials", comment: ""))
            } else {
                self.showAlert(NSLocalizedString("Connection failed", comment: ""), message: "\(nsError.localizedDescription)")
            }
        } else if response.statusCode == 403 {
            self.showAlert(NSLocalizedString("Authentication failed", comment: ""), message: NSLocalizedString("Incorrect API Key", comment: ""))
        }
    }
    
    // MARK: - OctoPrintSettingsDelegate
    
    func sdSupportChanged(sdSupport: Bool) {
        // Do nothing
    }
    
    func cameraOrientationChanged(newOrientation: UIImage.Orientation) {
        DispatchQueue.main.async {
            self.updateForCameraOrientation(orientation: newOrientation)
        }
    }
    
    // Notification that path to camera hosted by OctoPrint has changed
    func cameraPathChanged(streamUrl: String) {
        camerasViewController?.cameraPathChanged(streamUrl: streamUrl)
    }

    // Notification that a new camera has been added or removed. We rely on MultiCam
    // plugin to be installed on OctoPrint so there is no need to re-enter this information
    // URL to cameras is returned in /api/settings under plugins->multicam
    func camerasChanged(camerasURLs: Array<String>) {
        camerasViewController?.camerasChanged(camerasURLs: camerasURLs)
    }

    // React when device orientation changes
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        if subpanelsView != nil && subpanelsView.isHidden {
            // Do nothing if camera is in full screen
            return
        }
        if let printer = printerManager.getDefaultPrinter() {
            // Update layout depending on camera orientation
            updateForCameraOrientation(orientation: UIImage.Orientation(rawValue: Int(printer.cameraOrientation))!, devicePortrait: size.height == screenHeight)
        }
    }
    
    // MARK: - AppConfigurationDelegate
    
    func appLockChanged(locked: Bool) {
        DispatchQueue.main.async {
            self.configureBasedOnAppLockedState()
        }
    }
    
    // MARK: - EmbeddedCameraDelegate
    
    func imageAspectRatio(cameraIndex: Int, ratio: CGFloat) {
        let newRatio = ratio < 0.60
        if imageAspectRatio16_9 != newRatio {
            imageAspectRatio16_9 = newRatio
            if !transitioningNewPage {
                if let printer = printerManager.getDefaultPrinter() {
                    // Check if we need to update printer to remember aspect ratio of first camera
                    if cameraIndex == 0 && imageAspectRatio16_9 != printer.firstCameraAspectRatio16_9 {
                        let newObjectContext = printerManager.newPrivateContext()
                        let printerToUpdate = newObjectContext.object(with: printer.objectID) as! Printer
                        // Update aspect ratio of first camera
                        printerToUpdate.firstCameraAspectRatio16_9 = imageAspectRatio16_9
                        // Persist updated printer
                        printerManager.updatePrinter(printerToUpdate, context: newObjectContext)
                    }
                    let orientation = UIImage.Orientation(rawValue: Int(printer.cameraOrientation))!
                    // Add a tiny delay so the UI does not go crazy
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.updateForCameraOrientation(orientation: orientation)
                    }
                }
            }
        }
    }
    
    func startTransitionNewPage() {
        transitioningNewPage = true
    }
    
    func finishedTransitionNewPage() {
        transitioningNewPage = false
        if let printer = printerManager.getDefaultPrinter() {
            let orientation = UIImage.Orientation(rawValue: Int(printer.cameraOrientation))!
            // Add a tiny delay so the UI does not go crazy
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if self.subpanelsView != nil && self.subpanelsView.isHidden {
                    // Do nothing if camera is in full screen
                    return
                }
                self.updateForCameraOrientation(orientation: orientation)
            }
        }
    }
    
    // MARK: - WatchSessionManagerDelegate
    
    // Notification that a new default printer has been selected from the Apple Watch app
    func defaultPrinterChanged() {
        self.refreshNewSelectedPrinter()
    }
    
    // MARK: - Private functions
    
    fileprivate func showDefaultPrinter() {
        if let printer = printerManager.getDefaultPrinter() {
            // Update window title to Camera name
            DispatchQueue.main.async {
                self.navigationItem.title = printer.name
                if let navigationController = self.navigationController as? NavigationController {
                    navigationController.refreshForPrinterColors(color: printer.color)
                }
            }
            
            // Use last known aspect ratio of first camera of this printer
            // End user will have a better experience with this
            self.imageAspectRatio16_9 = printer.firstCameraAspectRatio16_9
            
            // Update layout depending on camera orientation
            DispatchQueue.main.async { self.updateForCameraOrientation(orientation: UIImage.Orientation(rawValue: Int(printer.cameraOrientation))!) }

            // Ask octoprintClient to connect to OctoPrint server
            octoprintClient.connectToServer(printer: printer)
        } else {
            DispatchQueue.main.async {
                self.notRefreshingReason = nil
                self.notRefreshingButton.isHidden = true
            }
            // Assume printer is not connected
            updateConnectButton(printerConnected: false)
            // Ask octoprintClient to disconnect from OctoPrint server
            octoprintClient.disconnectFromServer()
        }
    }
    
    fileprivate func refreshNewSelectedPrinter() {
        self.subpanelsViewController?.printerSelectedChanged()
        self.camerasViewController?.printerSelectedChanged()
        self.showDefaultPrinter()
    }

    fileprivate func updateConnectButton(printerConnected: Bool) {
        DispatchQueue.main.async {
            if !printerConnected {
                self.printerConnected = false
                self.connectButton.title = NSLocalizedString("Connect", comment: "")
            } else {
                self.printerConnected = true
                self.connectButton.title = NSLocalizedString("Disconnect", comment: "")
            }
        }
    }
    
    fileprivate func updateForCameraOrientation(orientation: UIImage.Orientation, devicePortrait: Bool = UIApplication.shared.statusBarOrientation.isPortrait) {
        if orientation == UIImage.Orientation.left || orientation == UIImage.Orientation.leftMirrored || orientation == UIImage.Orientation.rightMirrored || orientation == UIImage.Orientation.right {
            cameraHeightConstraint.constant = 281 + 50
        } else {
            if imageAspectRatio16_9 {
                cameraHeightConstraint.constant = devicePortrait ? camera16_9HeightConstraintPortrait! : cameral16_9HeightConstraintLandscape!
            } else {
                cameraHeightConstraint.constant = devicePortrait ? camera4_3HeightConstraintPortrait! : camera4_3HeightConstraintLandscape!
            }
        }
    }
    
    @objc func handleEmbeddedCameraTap() {
        if !subpanelsView.isHidden {
            // Hide the navigation bar on this view controller
            self.navigationController?.setNavigationBarHidden(true, animated: false)
            // Hide tab bar (located at the bottom)
            self.tabBarController?.tabBar.isHidden = true
            // Hide bottom panel
            subpanelsView.isHidden = true
            // Switch constraints priority. Height does not matter now. Bottom constraint matters with 0 to safe view
            cameraHeightConstraint.priority = UILayoutPriority(rawValue: 998)
            cameraBottomConstraint.priority = UILayoutPriority(rawValue: 999)
            // Flip orientation if needed
            let uiOrientation = UIApplication.shared.statusBarOrientation
            if uiOrientation != UIInterfaceOrientation.landscapeLeft && uiOrientation != UIInterfaceOrientation.landscapeRight {
                // We are not in landscape mode so change it to landscape
                uiOrientationBeforeFullScreen = uiOrientation  // Set previous value so we can go back to what it was
                // Rotate UI now
                UIDevice.current.setValue(Int(UIInterfaceOrientation.landscapeRight.rawValue), forKey: "orientation")
            } else {
                uiOrientationBeforeFullScreen = nil
            }
        } else {
            // Show the navigation bar on this view controller
            self.navigationController?.setNavigationBarHidden(false, animated: false)
            // Show tab bar (located at the bottom)
            self.tabBarController?.tabBar.isHidden = false
            // Show bottom panel
            subpanelsView.isHidden = false
            // Switch constraints priority. Height matters again. Bottom constraint no longer matters
            cameraHeightConstraint.priority = UILayoutPriority(rawValue: 999)
            cameraBottomConstraint.priority = UILayoutPriority(rawValue: 998)
            // Flip orientation if needed
            if let orientation = uiOrientationBeforeFullScreen {
                // When running full screen we are forcing landscape so we go back to portrait when leaving
                UIDevice.current.setValue(Int(orientation.rawValue), forKey: "orientation")
                uiOrientationBeforeFullScreen = nil
            }
        }
    }
    
    @objc func appWillEnterForeground() {
        // Show default printer
        showDefaultPrinter()
    }
    
    // We are using Container Views so this is how we keep a reference to the contained view controllers
    fileprivate func trackChildrenControllers() {
        guard let subpanelsChild = children.first as? SubpanelsViewController else  {
            fatalError("Check storyboard for missing SubpanelsViewController")
        }
        
        guard let camerasChild = children.last as? CamerasViewController else {
            fatalError("Check storyboard for missing CamerasViewController")
        }
        subpanelsViewController = subpanelsChild
        camerasViewController = camerasChild
    }
    
    fileprivate func configureBasedOnAppLockedState() {
        // Enable connect/disconnect button only if app is not locked
        connectButton.isEnabled = !appConfiguration.appLocked()
    }

    fileprivate func calculateCameraHeightConstraints() {
        let devicePortrait = UIApplication.shared.statusBarOrientation.isPortrait
        screenHeight = devicePortrait ? UIScreen.main.bounds.height : UIScreen.main.bounds.width
        let constraints = UIUtils.calculateCameraHeightConstraints(screenHeight: screenHeight)
        
        camera4_3HeightConstraintPortrait = constraints.cameraHeight4_3ConstraintPortrait
        camera4_3HeightConstraintLandscape = constraints.cameraHeight4_3ConstraintLandscape
        camera16_9HeightConstraintPortrait = constraints.camera16_9HeightConstraintPortrait
        cameral16_9HeightConstraintLandscape = constraints.cameral16_9HeightConstraintLandscape
    }
    
    fileprivate func obtainConnectionErrorReason(error: Error) -> String {
        if let nsError = error as NSError? {
            if nsError.code >= -9851 && nsError.code <= -9800 {
                // Some problem with SSL or the certificate
                return NSLocalizedString("Bad Certificate or SSL Problem", comment: "HTTPS failed for some reason. Could be bad certs, hostname does not match, cert expired, etc.")
            } else if nsError.domain == "kCFErrorDomainCFNetwork" && nsError.code == 2 {
                return NSLocalizedString("Server cannot be found", comment: "DNS resolution failed. Cannot resolve hostname")
            } else if nsError.domain == "NSPOSIXErrorDomain" && nsError.code == 61 {
                return NSLocalizedString("Could not connect to the server", comment: "Connection to server failed")
            }
        }
        return error.localizedDescription
    }
    
    fileprivate func showAlert(_ title: String, message: String) {
        UIUtils.showAlert(presenter: self, title: title, message: message, done: nil)
    }
    
    fileprivate func showConfirm(message: String, yes: @escaping (UIAlertAction) -> Void, no: @escaping (UIAlertAction) -> Void) {
        UIUtils.showConfirm(presenter: self, message: message, yes: yes, no: no)
    }
}
