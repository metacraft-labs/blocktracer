import Gaia from 0x8b148183c28ff88f
import HybridCustody from 0xd8a7e05a7ac670c0

/// what every Streetball game mode shares: who is playing, proof that they
/// hold the Ballerz and Sneakerz they bring, and the ratings those turn into
access(all) contract Streetball {

    access(all) entitlement Play

    access(all) let PlayerStoragePath: StoragePath

    access(all) let ballerzSetName: String
    access(all) let sneakerzSetName: String
    access(all) let maxSkill: UInt8

    access(all) event PlayerCreated(uuid: UInt64)

    /// a player is identified by the account their Player is stored in, so
    /// game modes take an authorized reference to it instead of an address
    access(all) resource Player {}

    access(all) fun createPlayer(): @Player {
        let player <- create Player()
        emit PlayerCreated(uuid: player.uuid)
        return <- player
    }

    access(all) view fun addressOf(_ player: auth(Play) &Player): Address {
        return player.owner?.address ?? panic("Streetball: the Player must be saved in account storage before it can play")
    }

    access(all) struct Skills {
        access(all) let dunks: UInt8
        access(all) let shooting: UInt8
        access(all) let playmaking: UInt8
        access(all) let defense: UInt8

        view init(dunks: UInt8, shooting: UInt8, playmaking: UInt8, defense: UInt8) {
            self.dunks = dunks
            self.shooting = shooting
            self.playmaking = playmaking
            self.defense = defense
        }

        access(all) view fun total(): UInt16 {
            return UInt16(self.dunks) + UInt16(self.shooting) + UInt16(self.playmaking) + UInt16(self.defense)
        }

        access(all) view fun plus(dunks: Int16, shooting: Int16, playmaking: Int16, defense: Int16): Skills {
            return Skills(
                dunks: Streetball.clampSkill(Int16(self.dunks) + dunks),
                shooting: Streetball.clampSkill(Int16(self.shooting) + shooting),
                playmaking: Streetball.clampSkill(Int16(self.playmaking) + playmaking),
                defense: Streetball.clampSkill(Int16(self.defense) + defense)
            )
        }
    }

    access(all) struct Baller {
        access(all) let nftID: UInt64
        /// the collection id people use, as in "Baller #159". sets overlap in
        /// this numbering, so games key on nftID and only display this
        access(all) let number: String
        access(all) let team: String
        access(all) let role: String
        access(all) let skills: Skills

        view init(nftID: UInt64, number: String, team: String, role: String, skills: Skills) {
            self.nftID = nftID
            self.number = number
            self.team = team
            self.role = role
            self.skills = skills
        }
    }

    access(all) struct Sneaker {
        access(all) let nftID: UInt64
        access(all) let number: String
        access(all) let jump: UInt8
        access(all) let rarity: String
        access(all) let enhancement: String
        access(all) let dripfactor: Int8

        view init(nftID: UInt64, number: String, jump: UInt8, rarity: String, enhancement: String, dripfactor: Int8) {
            self.nftID = nftID
            self.number = number
            self.jump = jump
            self.rarity = rarity
            self.enhancement = enhancement
            self.dripfactor = dripfactor
        }
    }

    /// a Baller with its Sneaker laced up. `skills` already includes the gear
    access(all) struct Hooper {
        access(all) let baller: Baller
        access(all) let sneaker: Sneaker?
        access(all) let skills: Skills

        view init(baller: Baller, sneaker: Sneaker?, skills: Skills) {
            self.baller = baller
            self.sneaker = sneaker
            self.skills = skills
        }
    }

    access(all) view fun clampSkill(_ value: Int16): UInt8 {
        if value < 0 {
            return 0
        }
        if value > Int16(self.maxSkill) {
            return self.maxSkill
        }
        return UInt8(value)
    }

    /// whether `player` may field NFTs that sit in `holder`'s collection: their
    /// own, or those of a child account linked to them through HybridCustody
    /// (how a Dapper wallet, which cannot sign game transactions, gets to play).
    /// the link is read from the holder's side on purpose. only the holder can
    /// publish there, so a forged link can only lend out the forger's own NFTs
    access(all) view fun controls(player: Address, holder: Address): Bool {
        if player == holder {
            return true
        }
        if let owned = getAccount(holder).capabilities.borrow<&{HybridCustody.OwnedAccountPublic}>(HybridCustody.OwnedAccountPublicPath) {
            // a look-alike could lie about the link or panic and block whoever
            // has to read it, so only the real HybridCustody type is asked
            if owned.getType() != Type<@HybridCustody.OwnedAccount>() {
                return false
            }
            return owned.getRedeemedStatus(addr: player) == true
        }
        return false
    }

    access(all) view fun borrowNFT(holder: Address, nftID: UInt64): &Gaia.NFT? {
        if let collection = getAccount(holder).capabilities.borrow<&{Gaia.CollectionPublic}>(Gaia.CollectionPublicPath) {
            // a look-alike collection could forward to someone else's NFTs
            if collection.getType() != Type<@Gaia.Collection>() {
                return nil
            }
            if let nft = collection.borrowGaiaNFT(id: nftID) {
                if nft.owner?.address == holder {
                    return nft
                }
            }
        }
        return nil
    }

    access(all) view fun holds(holder: Address, nftID: UInt64): Bool {
        return self.borrowNFT(holder: holder, nftID: nftID) != nil
    }

    access(all) view fun getBaller(holder: Address, nftID: UInt64): Baller {
        let nft = self.borrowNFT(holder: holder, nftID: nftID)
            ?? panic("Streetball: \(holder) does not hold NFT \(nftID)")
        assert(
            Gaia.getSetName(setID: nft.data.setID) == self.ballerzSetName,
            message: "Streetball: NFT \(nftID) is not a Baller"
        )
        let metadata = Gaia.getTemplateMetaData(templateID: nft.data.templateID)!
        return Baller(
            nftID: nft.id,
            number: metadata["id"] ?? "",
            team: metadata["team"] ?? "",
            role: metadata["role"] ?? "",
            skills: Skills(
                dunks: self.parseSkill(metadata, "dunks"),
                shooting: self.parseSkill(metadata, "shooting"),
                playmaking: self.parseSkill(metadata, "playmaking"),
                defense: self.parseSkill(metadata, "defense")
            )
        )
    }

    access(all) view fun getSneaker(holder: Address, nftID: UInt64): Sneaker {
        let nft = self.borrowNFT(holder: holder, nftID: nftID)
            ?? panic("Streetball: \(holder) does not hold NFT \(nftID)")
        assert(
            Gaia.getSetName(setID: nft.data.setID) == self.sneakerzSetName,
            message: "Streetball: NFT \(nftID) is not a Sneaker"
        )
        let metadata = Gaia.getTemplateMetaData(templateID: nft.data.templateID)!
        return Sneaker(
            nftID: nft.id,
            number: metadata["id"] ?? "",
            jump: self.parseSkill(metadata, "jump"),
            rarity: metadata["rarity"] ?? "",
            enhancement: metadata["enhancement"] ?? "",
            dripfactor: Int8.fromString(metadata["dripfactor"] ?? "") ?? 0
        )
    }

    access(self) view fun parseSkill(_ metadata: {String: String}, _ field: String): UInt8 {
        let value = UInt8.fromString(metadata[field] ?? "")
            ?? panic("Streetball: metadata field \(field) is missing or not a number")
        return value > self.maxSkill ? self.maxSkill : value
    }

    /// what a Sneaker adds to its Baller, as [dunks, shooting, playmaking, defense].
    /// deliberately small next to a 60 to 99 skill, and documented in the README
    access(all) view fun gearBoost(_ sneaker: Sneaker): [Int16] {
        var dunks: Int16 = 0
        var shooting: Int16 = 0
        var playmaking: Int16 = 0
        var defense: Int16 = 0

        if sneaker.jump > 60 {
            dunks = Int16((sneaker.jump - 60) / 13)
        }

        switch sneaker.rarity {
            case "Uncommon": defense = 1
            case "Rare": defense = 1
            case "Custom": defense = 1
            case "Legendary": defense = 2
            case "Iconic": defense = 3
        }

        switch sneaker.enhancement {
            case "Bullseye": shooting = 3
            case "Ankle Breaker": playmaking = 2
            case "Drive the Lane": dunks = dunks + 2
            case "Stopping on a Dime":
                shooting = 1
                defense = defense + 1
        }

        if sneaker.dripfactor < 0 {
            playmaking = playmaking - 1
        } else {
            playmaking = playmaking + Int16(sneaker.dripfactor / 2)
        }

        return [dunks, shooting, playmaking, defense]
    }

    /// the team whose colors a Sneaker wears, or nil for a generic colorway.
    /// team-color styles read "<team> <code>", like "D.C. Dobermans 701"
    access(all) view fun getSneakerTeam(holder: Address, nftID: UInt64): String? {
        let nft = self.borrowNFT(holder: holder, nftID: nftID)
            ?? panic("Streetball: \(holder) does not hold NFT \(nftID)")
        let metadata = Gaia.getTemplateMetaData(templateID: nft.data.templateID)!
        if (metadata["teamcolor"] ?? "") != "Yes" {
            return nil
        }
        let style = metadata["style"] ?? ""
        let words = style.split(separator: " ")
        if words.length < 2 {
            return nil
        }
        return style.slice(from: 0, upTo: style.length - words[words.length - 1].length - 1)
    }

    /// a Sneaker in its Baller's team colors adds playmaking +1 and defense +1.
    /// Team Flow and Team Dapper Ballerz add " (M)" or " (W)" to the team name
    access(all) view fun teamMatch(ballerTeam: String, sneakerTeam: String?): Bool {
        if sneakerTeam == nil {
            return false
        }
        if ballerTeam == sneakerTeam! {
            return true
        }
        let prefix = "\(sneakerTeam!) ("
        return ballerTeam.length > prefix.length
            && ballerTeam.slice(from: 0, upTo: prefix.length) == prefix
    }

    /// reads a Baller and its optional Sneaker out of `holder`'s collection,
    /// which is also the proof that the holder owns both right now
    access(all) view fun suitUp(holder: Address, ballerID: UInt64, sneakerID: UInt64?): Hooper {
        let baller = self.getBaller(holder: holder, nftID: ballerID)
        if sneakerID == nil {
            return Hooper(baller: baller, sneaker: nil, skills: baller.skills)
        }
        let sneaker = self.getSneaker(holder: holder, nftID: sneakerID!)
        let boost = self.gearBoost(sneaker)
        let team: Int16 = self.teamMatch(
            ballerTeam: baller.team,
            sneakerTeam: self.getSneakerTeam(holder: holder, nftID: sneakerID!)
        ) ? 1 : 0
        return Hooper(
            baller: baller,
            sneaker: sneaker,
            skills: baller.skills.plus(dunks: boost[0], shooting: boost[1], playmaking: boost[2] + team, defense: boost[3] + team)
        )
    }

    /// the salary tiers the off-chain Salary Cap League uses, by on-chain
    /// overall (the average of the four skills, so thresholds are times four)
    access(all) view fun salary(_ skills: Skills): UInt8 {
        let total = skills.total()
        if total >= 396 { return 20 }
        if total >= 380 { return 15 }
        if total >= 368 { return 13 }
        if total >= 360 { return 10 }
        if total >= 352 { return 8 }
        if total >= 340 { return 7 }
        if total >= 328 { return 6 }
        if total >= 320 { return 5 }
        if total >= 312 { return 4 }
        if total >= 300 { return 3 }
        if total >= 280 { return 2 }
        return 1
    }

    access(all) view fun today(): UInt64 {
        return UInt64(getCurrentBlock().timestamp) / 86400
    }

    init() {
        self.PlayerStoragePath = /storage/StreetballPlayer
        self.ballerzSetName = "Ballerz"
        self.sneakerzSetName = "Sneakerz"
        self.maxSkill = 99
    }
}
