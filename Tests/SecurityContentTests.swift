import Foundation

@main struct SecurityContentTests {
    static func main() {
        var count = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1 }
        let guest=UUID(),other=UUID(),camera=UUID(),chain=UUID(),legal=UUID()
        var ledger=SecurityInventory(),cash=120
        ledger.register(camera,kind:.camera,guest:guest)
        ledger.register(chain,kind:.chain,guest:guest)
        ledger.register(legal,kind:.headphones,guest:guest)
        check(!ledger.acquire(camera,from:other,wave:1,confiscate:false,money:&cash) && cash==120,"other guest cannot sell this item")
        check(!ledger.acquire(legal,from:guest,wave:1,confiscate:true,money:&cash),"legal belongings cannot be confiscated")
        check(ledger.acquire(camera,from:guest,wave:1,confiscate:false,money:&cash) && cash==45,"buy pays once and transfers ownership")
        check(!ledger.acquire(camera,from:guest,wave:1,confiscate:false,money:&cash) && cash==45,"repeated buy cannot charge twice or duplicate goods")
        check(ledger.acquire(chain,from:guest,wave:1,confiscate:true,money:&cash) && cash==45,"banned chain can be seized without a purchase")
        check(ledger.sell(camera,money:&cash) && cash==93,"sale pays the actual resale price")
        check(!ledger.sell(camera,money:&cash) && cash==93,"repeated sale cannot create money")
        let expensive=UUID();ledger.register(expensive,kind:.camera,guest:guest);cash=10
        check(!ledger.acquire(expensive,from:guest,wave:1,confiscate:false,money:&cash) && cash==10,"insufficient funds leave cash and ownership unchanged")
        for wave in 1...9 {
            check(SecurityGoods.chain.forbidden(wave:wave) == (wave%3==1),"chain policy follows the posted shift")
            check(SecurityGoods.skateboard.forbidden(wave:wave) == (wave%3==0),"large-item policy follows the posted shift")
            check(SecurityGoods.sealedCase.forbidden(wave:wave),"contraband stays forbidden every shift")
            check(!SecurityGoods.camera.forbidden(wave:wave),"ordinary cameras stay legal")
        }
        var full=SecurityInventory();cash=1000
        for _ in 0..<8 { let id=UUID();full.register(id,kind:.camera,guest:guest);check(full.acquire(id,from:guest,wave:1,confiscate:false,money:&cash),"inventory accepts a free slot") }
        let excess=UUID();full.register(excess,kind:.camera,guest:guest);let before=cash
        check(!full.acquire(excess,from:guest,wave:1,confiscate:false,money:&cash) && cash==before && full.count==8,"full inventory cannot consume cash or spawn more items")
        full.discardGuest(guest)
        check(full.entries.count==8,"departing guests discard unsold records while owned items survive")
        for _ in 0..<100 {let visitor=UUID(),id=UUID();full.register(id,kind:.speaker,guest:visitor);full.discardGuest(visitor)}
        check(full.entries.count==8,"guest turnover does not grow the ledger")
        ledger.discardGuest(guest)
        check(ledger.entries.count==1 && ledger.entries[chain]?.holder == .player,"cleanup keeps seized items and drops sold tombstones")
        var body=SecurityRagdoll(impulse:SIMD3(1,1,-3))
        for _ in 0..<600 {body.update(dt:1/120)}
        check(body.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite },"ragdoll remains finite after five seconds")
        check(body.points.allSatisfy { $0.y>=0.06 },"all joints stay above the floor")
        check(body.points[2].y<0.7,"head physically falls instead of keeping a standing pose")
        check(body.points[5] != SecurityRagdoll.rest[5] && body.points[11] != SecurityRagdoll.rest[11],"hands and feet move independently")
        let error=SecurityRagdoll.links.map { abs(SecurityRagdoll.length(body.points[$0.b]-body.points[$0.a])-$0.length) }.max()!
        check(error<0.04,"articulated joints retain their bone lengths")
        let frozen=body.points;body.update(dt:0)
        check(body.points==frozen,"pausing leaves every joint exactly still")
        body.update(dt:.nan);check(body.points==frozen,"invalid timing cannot corrupt physics")
        var sixty=SecurityRagdoll(impulse:SIMD3(1,1,-3)),thirty=sixty
        for _ in 0..<120 {sixty.update(dt:1/60)}
        for _ in 0..<60 {thirty.update(dt:1/30)}
        check(zip(sixty.points,thirty.points).allSatisfy {SecurityRagdoll.length($0-$1)<0.04},"ragdoll motion is consistent at 30 and 60 FPS")
        var raised=SecurityRagdoll(impulse:SIMD3(0,0,-2),floor:-1)
        for _ in 0..<600 {raised.update(dt:1/120)}
        check(raised.points.allSatisfy {$0.y >= -0.94},"floor follows the guest's local height when dropped from a grip")
        for kind in SecurityGoods.allCases {
            let model=SecurityModels.make(kind)
            check(model.childNodes.count>=4,"every item has several modeled details")
            check(model.childNodes.allSatisfy {$0.geometry?.firstMaterial != nil},"all model parts have materials")
        }
        for index in 0..<5 {check(SecurityModels.tool(index).childNodes.count>=4,"security tools have bodies, controls and functional details")}
        let skin=SecurityModels.material(.white),head=SCNNode()
        let view=SecurityRagdollView(skin:skin,cloth:skin,headModel:head)
        view.update(body)
        check(head.simdPosition==body.points[2],"rendered head follows the simulated joint")
        check(view.root.childNodes.count==19,"ragdoll renderer uses a bounded set of body parts")
        // Actual game transactions move the original nodes and change the guest's live violation state.
        let game=SecurityVRGame(),scene=SCNScene()
        game.start(in:scene,cameraOrigin:.zero,cameraForward:SIMD3(0,0,-1))
        let actor=SecurityGuest(hasContraband:false,isDrunk:false,isAggressive:false,speed:1,wave:1)
        for id in Array(actor.goods.keys) {_ = actor.removeGoods(id)}
        actor.addGoods(.chain,at:SIMD3(0,1.3,0.13));actor.phase = .atGate;actor.arrived = true
        game.root.addChildNode(actor.root);game.guest=actor
        func registerGoods() {
            for (id,item) in actor.goods {game.inventory.register(id,kind:item.kind,guest:actor.id);game.goodsNodes[id]=item.node;game.nodeGoods[ObjectIdentifier(item.node)]=id}
        }
        registerGoods()
        let necklace=actor.goods.keys.first!,necklaceNode=actor.goods[necklace]!.node
        check(actor.hasContraband,"chain is a live violation of this guest's arrival rules")
        actor.scanned=true
        game.tradeFocus=necklace
        check(game.trade(game.seizeButton),"actual seize button transfers forbidden property")
        check(!actor.hasContraband && actor.goods.isEmpty && necklaceNode.parent === game.root,"taking the necklace clears the violation and moves the original model")
        check(game.goodsSlots[necklace]==0,"first acquired item reserves its own shelf slot")
        check(actor.verdict.current == "Вещи в порядке","seizure refreshes the visible scan verdict as well as the underlying rule")
        let afterSeize=game.money
        game.tradeFocus=necklace
        check(!game.trade(game.seizeButton) && game.money==afterSeize,"actual repeated seizure cannot pay again")
        actor.addGoods(.camera,at:SIMD3(0.3,1,-0.2));registerGoods()
        let cameraID=actor.goods.keys.first!,cameraNode=actor.goods[cameraID]!.node
        game.tradeFocus=cameraID
        check(game.trade(game.buyButton) && game.money==45,"actual purchase deducts price from the game wallet")
        check(cameraNode.parent === game.root && game.pickables.contains {$0 === cameraNode},"purchased model becomes a grabbable object")
        game.heldItem=cameraNode;game.tradeFocus=cameraID
        check(game.trade(game.sellButton) && game.money==93,"held item can be sold to the actual waiting guest")
        check(game.heldItem == nil && cameraNode.parent == nil && !game.pickables.contains {$0 === cameraNode},"sale clears the grip and removes the same physical item")
        check(game.goodsSlots[cameraID] == nil && game.goodsSlots[necklace]==0,"sale frees only that item's shelf slot")
        game.tradeFocus=cameraID
        check(!game.trade(game.sellButton) && game.money==93,"actual duplicate sale has no effect")
        let torso=actor.root.convertPosition(actor.chestLocalPoint(),to:game.root).simd3
        game.impactGuest(from:torso+SIMD3(0,0,0.1),to:torso,velocity:SIMD3(0,0,-3))
        check(actor.phase == .dropping && actor.ragdoll != nil,"physical item contact starts the actual guest's articulated fall")
        check(game.money==73,"hitting a clean guest applies a penalty")
        game.updateGuest(dt:0.04);let served=game.servedInWave,paid=game.money
        for _ in 0..<10 {game.impactGuest(from:torso,to:torso,velocity:SIMD3(0,0,-3));game.updateGuest(dt:0.04)}
        check(game.servedInWave==served && game.money==paid && served==1,"one knockdown resolves the guest exactly once")
        game.paused=true;let pausedPoints=actor.ragdoll!.points;testClock += 0.1
        game.update(ray:WorldRay(origin:.zero,direction:SIMD3(0,1,0)),pinch:false)
        check(actor.ragdoll!.points==pausedPoints,"pause freezes the production guest's ragdoll")
        game.paused=false
        let cancelled=SecurityGuest(hasContraband:false,isDrunk:false,isAggressive:false,speed:1)
        cancelled.phase = .held;game.guest=cancelled;game.root.addChildNode(cancelled.root);game.heldGuest=cancelled
        let beforeCancel=game.money,decisions=game.progress.decisions
        game.releaseHold(cancelled:true);game.updateGuest(dt:0.04)
        check(game.money==beforeCancel && game.progress.decisions==decisions,"tracking-loss drop cannot grant money or a shift decision")
        let resolved=SecurityGuest(hasContraband:true,isDrunk:false,isAggressive:true,speed:1)
        resolved.phase = .held;resolved.resolved=true;resolved.root.position.z = -1
        game.guest=resolved;game.heldGuest=resolved;game.root.addChildNode(resolved.root)
        let scoreBefore=game.score,moneyBefore=game.money,servedBefore=game.servedInWave
        game.releaseHold()
        check(game.score==scoreBefore && game.money==moneyBefore && game.servedInWave==servedBefore,"ejecting an already resolved guest cannot repeat a decision or reward")
        game.stop()
        print("PASS: \(count) Security VR trading, inventory, articulated ragdoll and production 3D model checks")
    }
}
