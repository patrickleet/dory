import Testing
@testable import Dory

struct MachineUseCaseTests {
    @Test func catalogNonEmptyUniqueIDs() {
        #expect(!MachineUseCase.all.isEmpty)
        #expect(Set(MachineUseCase.all.map(\.id)).count == MachineUseCase.all.count)
    }

    @Test func everyUseCaseResolvesADistroAndPrefill() {
        for useCase in MachineUseCase.all {
            #expect(useCase.distro != nil, "\(useCase.id) distro")
            #expect(useCase.prefill != nil, "\(useCase.id) prefill")
        }
    }

    @Test func recipeUseCasesResolveAndAreAptGated() {
        for useCase in MachineUseCase.all where useCase.recipeID != nil {
            #expect(useCase.recipe != nil, "\(useCase.id) recipe resolves")
            #expect(useCase.distro?.pkg == .apt, "\(useCase.id) recipe needs apt distro")
        }
    }

    @Test func cleanUseCaseHasNoRecipe() {
        #expect(MachineUseCase.forID("clean")?.recipeID == nil)
    }

    @Test func goAndRustAreSeparateCards() {
        #expect(MachineUseCase.forID("systems") == nil)
        #expect(MachineUseCase.forID("go")?.recipeID == "go")
        #expect(MachineUseCase.forID("rust")?.recipeID == "rust")
    }

    @Test func resourceDefaultsWithinFormStepperBounds() {
        for useCase in MachineUseCase.all {
            #expect((1...8).contains(useCase.cpus), "\(useCase.id) cpus")
            #expect((1...16).contains(useCase.memoryGB), "\(useCase.id) memoryGB")
        }
    }

    @Test func prefillArchIsDistroDefault() {
        for useCase in MachineUseCase.all {
            #expect(useCase.prefill?.arch == useCase.distro?.defaultArch())
        }
    }
}
