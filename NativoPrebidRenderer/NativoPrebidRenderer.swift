/*   Copyright 2018-2024 Prebid.org, Inc.
 
  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at
 
  http://www.apache.org/licenses/LICENSE-2.0
 
  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
 */


import UIKit
#if canImport(PrebidMobile)
import PrebidMobile
#endif

/**
 Nativo's custom Prebid renderer
 */
public class NativoPrebidRenderer: NSObject, PrebidMobilePluginRenderer, DisplayViewLoadingDelegate {

    public static let NAME = "NativoRenderer"
    public static let VERSION = "1.0.0"
    public let name = NativoPrebidRenderer.NAME
    public let version = NativoPrebidRenderer.VERSION
    public var data: [String: Any]?
    var bannerLoadingDelegate: DisplayViewLoadingDelegate?
    
    public func createBannerView(
        with frame: CGRect,
        bid: Bid,
        adConfiguration: AdUnitConfig,
        loadingDelegate: DisplayViewLoadingDelegate,
        interactionDelegate: DisplayViewInteractionDelegate
    ) -> (UIView & PrebidMobileDisplayViewProtocol)? {
        
        let displayView = DisplayView(
            frame: frame,
            bid: bid,
            adConfiguration: adConfiguration
        )
        
        self.bannerLoadingDelegate = loadingDelegate
        displayView.interactionDelegate = interactionDelegate
        displayView.loadingDelegate = self
        
        return displayView
    }
    
    public func createInterstitialController(
        bid: Bid,
        adConfiguration: AdUnitConfig,
        loadingDelegate: InterstitialControllerLoadingDelegate,
        interactionDelegate: InterstitialControllerInteractionDelegate
    ) -> PrebidMobileInterstitialControllerProtocol? {
        let interstitialController = InterstitialController(
            bid: bid,
            adConfiguration: adConfiguration
        )
        
        interstitialController.loadingDelegate = loadingDelegate
        interstitialController.interactionDelegate = interactionDelegate
        
        return interstitialController
    }
    
    // MARK: - DisplayViewLoadingDelegate
    
    public func displayViewDidLoadAd(_ displayView: UIView) {
        // Notify the downstream DisplayViewLoadingDelegate
        self.bannerLoadingDelegate?.displayViewDidLoadAd(displayView)
        
        // Forced to briefly wait for Prebid's AdViewManager to finish before PBMWebView gets injected
        DispatchQueue.main.async {
            // Allow the inner web view to expand to the full width of its parent
            if let pbmWebView = displayView.subviews.first {
                NSLayoutConstraint.activate([
                    pbmWebView.widthAnchor.constraint(equalTo: displayView.widthAnchor),
                ])
            } else {
                let error = NSError(
                    domain: "NativoPrebidRenderer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Nativo renderer expected a subview on DisplayView, but none was found."]
                )
                Log.error(error.localizedDescription, filename: #file, line: #line, function: #function)
            }

        }
    }
    
    public func displayView(_ displayView: UIView, didFailWithError error: any Error) {
        self.bannerLoadingDelegate?.displayView(displayView, didFailWithError: error)
    }
}
