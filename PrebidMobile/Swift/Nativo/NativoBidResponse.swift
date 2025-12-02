import Foundation

@objcMembers
public class NativoBidResponse: BidResponse {

    required init(rawBidResponse: RawBidResponse?) {
        super.init(rawBidResponse: rawBidResponse)
    }
    
    // Create bid using NativoBid
    override func createBids(rawBidResponse: RawBidResponse) {
        var allBids: [Bid] = []
        if let seatbid = rawBidResponse.seatbid {
            for nextSeatBid in seatbid {
                guard let bids = nextSeatBid.bid else { continue }
                for nextBid in bids {
                    let bid = NativoBid(bid: nextBid)
                    allBids.append(bid)
                    
                    // Select Nativo's winning bid
                    if bid.price > self.winningBid?.price ?? 0 {
                        self.winningBid = bid
                    }
                }
            }
        }
        self.allBids = allBids
    }
}
